#!/bin/bash

SELF=$(readlink -f $0)
RSYNCSYNC=$(dirname $SELF)/rsyncsync.sh
DEBUG=${DEBUG:-}

: ${BACKUP_ENCFS_ENCRYPT_TIMEOUT:=15}
: ${BACKUP_ENCFS_DECRYPT_TIMEOUT:=5}


init() {
    set -eu
    shopt -s nullglob dotglob
    init_commands
    test "${1:-}" && dispatch "$@"
    test $? -eq 0 && exit 0
    usage
    exit 1
}

dispatch() {
    check_environ
    cmd=${1//-/_}
    shift
    case "$COMMAND_FUNCS" in
        *cmd_"$cmd"*)
            cmd_$cmd "$@"
            return 0
            ;;
    esac
    return 1
}

init_commands() {
    COMMAND_FUNCS=$(declare -f | grep ^cmd_ | cut -d' ' -f1)
}

check_environ() {
    set +u
    test "$SSH"   || SSH=$(type -p ssh || true)
    test "$SSHFS" || SSHFS=$(type -p sshfs || true)
    test "$ENCFS" || ENCFS=$(type -p encfs || true)
    test "$SSH"             || fatal ssh not found
    test "$SSHFS"           || fatal ssfs not found
    test "$ENCFS"           || fatal encfs not found
    test -n "$BACKUP_ENCFS_CONFIG" || fatal encfs config not set
    test -r "$BACKUP_ENCFS_CONFIG" || fatal encfs config missing
    test -n "$BACKUP_ENCFS_KEY"    || fatal encfs key not set
    test -r "$BACKUP_ENCFS_KEY"    || fatal encfs key missing
    test -x "$RSYNCSYNC"    || fatal "$RSYNCSYNC" not executable
    test "$BACKUP_TMP" || fatal "BACKUP_TMP not defined"
    mkdir -m 0700 -p "$BACKUP_TMP" || fatal "cannot write to $BACKUP_TMP"
    set -u
}

usage() {
    echo Usage:
    echo "$0 COMMAND"
    echo
    echo COMMAND:
    for cmd in $COMMAND_FUNCS
    do
        cmd=${cmd##cmd_}
        echo "  ${cmd//_/-}"
    done
}

cmd_config_targets() {
    try_targets_from_config "$@"
}

cmd_config_history() {
    mount_history_from_config "$@"
}

cmd_config_verify() {
    verify_from_config "$@"
}
cmd_config_purge() {
    purge_history_from_config "$@"
}

cmd_try_target_args() {
    try_targets "$@"
}

cmd_sync_one() {
    sync_one "$@"
}

cmd_history() {
    mount_history "$@"
}

cmd_clean_mounts() {
    clean_mounts
}

cmd_show_mounts() {
    show_mounts
}

cmd_show_config() {
    show_config "$@"
}

show_mounts() {
    clean_mounts
    for d in "$BACKUP_TMP"/*
    do
        mountpoint -q "$d" && echo "$d"
    done
}

clean_mounts() {
    for d in "$BACKUP_TMP"/*
    do
        mountpoint -q "$d" || rmdir "$d"
    done
}

show_config() {
    local id="${1:-}"
    test "$id" || fatal "missing ID arg"
    local var=BACKUP_SOURCE_$id
    local source=${!var:-}
    test "$source" || fatal "$var unset"
    var=BACKUP_TARGET_$id
    local target=${!var:-}
    test "$target" || fatal "$var unset"
    test "${BACKUP_TARGETS:-}" || fatal "missing BACKUP_TARGETS"
    local targets=("${BACKUP_TARGETS[@]/%/\/$target}")
    echo "$source"
    local x
    for x in "${targets[@]}"
    do
        echo " -> $x"
    done

}

try_targets_from_config() {
    local id="${1:-}" var=
    test "$id" || fatal "missing ID arg"
    var=BACKUP_SOURCE_$id
    local source=${!var:-}
    test "$source" || fatal "$var unset"
    var=BACKUP_TARGET_$id
    local target=${!var:-}
    test "$target" || fatal "$var unset"
    test "${BACKUP_TARGETS:-}" || fatal "missing BACKUP_TARGETS"
    local targets=("${BACKUP_TARGETS[@]/%/\/$target}")
    try_targets "$source" "${targets[@]}"
}

mount_history_from_config() {
    local id="${1:-}" num="${2:-}" mount="${3:-}"
    test "$id" || fatal "missing ID arg"
    test "$num" || fatal "missing target number"
    local var=BACKUP_TARGET_$id
    local target=${!var:-}
    test "$target" || fatal "$var unset"
    test "${BACKUP_TARGETS:-}" || fatal "missing BACKUP_TARGETS"
    local target="${BACKUP_TARGETS[num]}/$target"
    mount_history "$target" "$mount"
}

verify_from_config() {
    local id="${1:-}" num="${2:-}"
    local encfs sshfs s
    s=$(mount_history_from_config "$id" "$num")
    local var=BACKUP_SOURCE_$id
    local source=${!var:-}
    echo diff -urq "$source" "$encfs"/latest
    echo fusermount -u $encfs
    echo fusermount -u $sshfs
}

purge_history_from_config() {
    local id="${1:-}" num="${2:-}"
    local encfs sshfs s
    s=$(mount_history_from_config "$id" "$num")
    eval "$s"
    local target="${BACKUP_TARGETS[num]}/$id"
    local keep=${BACKUP_KEEP:-100}
    purge_history
    sleep 1
    fusermount -u $encfs
    test "$sshfs" && fusermount -u $sshfs
}

purge_history() {
    echo purge $keep "$target" "$encfs" "$sshfs"
    local all d crypt_d remote_d
    local n etc
    local host script root

    all=("$encfs"/2*)
    n=${#all[@]}
    ((n<=keep)) && return 0
    i=0
    local i
    for ((i=0; i<n; ++i))
    do
        clear_d=${all[i]}
        if (( i % 2 == 1 || i > n / 2 ))
        then
            echo "keep ${clear_d##*/}"
            continue
        fi
        echo "nuke ${clear_d##*/}"
        inode=$(stat -c%i $clear_d)
        crypt_d=$(find $sshfs -maxdepth 1 -type d -inum $inode)
        root=${target##*:}
        d="$root/$(basename $crypt_d)"
        script="test -d '$d' && chmod -R +w $d && rm -rf -- '$d'"
        if [[ "$target" = *:* ]]
        then
            host=${target%%:*}
            ssh $host "$script"
        else
            eval "$script"
        fi
    done
}

try_targets() {
    local source="${1:-}" target
    test "$source" || fatal "missing source arg"
    source=$(readlink -f "$source")
    shift
    test "$*" || fatal "missing target(s)"
    local errors=()
    local output= rc
    for target in "$@"
    do
        if [[ "$target" != *:* && ! -d "$(dirname $target)" ]]
        then
            output="skipping '$target'"
            test "$DEBUG" &&
                echo "$output" ||
                errors+=("skipping '$target'")
            continue
        fi
        if [ "$DEBUG" ]
        then
            sync_one "$source" "$target" && return 0
        else
            output=$(sync_one "$source" "$target" 2>&1)
            [ $? -eq 0 ] && return 0
            errors+=("$output")
        fi
    done
    stderr no targets succeeded
    if [ -z "$DEBUG" ]
    then
        for output in "${errors[@]}"
        do
            stderr "$output"
        done
    fi
    exit 1
}

mount_history() {
    local crypt=${1:-} mount=${2:-}

    test "$crypt" || fatal "missing crypt arg"

    if [[ "$crypt" = *:* ]]
    then
        sshcrypt=$crypt
        crypt=$(tmpdir sshfs)
        mount_sshfs "$sshcrypt" "$crypt"
        echo "sshfs='$crypt'"
    fi

    mount=$(ensure_dir clear $mount)
    mount_decrypted "$crypt" "$mount"
    echo "encfs='$mount'"
}

do_encrypt() {
    is_dir "${1-}" || { echo 'require existing directory' >&2; exit 1; }
    local clear=$1 mount=${2:-}
    mount=$(ensure_dir crypt $mount)
    mount_encrypted "$clear" "$mount"
    echo "encfs='$mount'"
}

do_sshfs() {
    local sshpath=$1 mount=${2:-}
    mount=$(ensure_dir sshfs $mount)
    mount_sshfs "$sshpath" "$mount"
    echo "sshfs='$crypt'"
}

sync_one() {
    local source=${1:-} target=${2:-}
    test "$source"    || fatal "missing source arg"
    test "$target"    || fatal "missing target"
    test -d "$source" || fatal "missing source dir"
    local dotpath="$source/.rsyncsync"
    local mountfile="$dotpath/encfs"
    local mount=$(cat "$mountfile" 2>/dev/null || true)
    if test "$mount"
    then
        if ! grep -q "$mount" /proc/mounts
        then
            echo "stale mount $mount"
            mount=
        elif ! test -w "$mount"
        then
            echo "unwritable mount $mount"
            mount=
        #else
        #    echo "reusing mount $mount"
        fi
    fi
    test "$mount" || {
        mount=$(tmpdir crypt)
        echo new mount $mount
    }
    mount_encrypted "$source" "$mount" || {
        echo "failed mounting encrypted"
        exit 1
    }
    mkdir -p "$dotpath"
    echo "$mount" > "$mountfile"

    DEBUG=$DEBUG \
    SSH=$SSH     \
    $RSYNCSYNC "$source" "$mount" "$target"
}

mount_encrypted() {
    local clear=$1 mount=$2
    grep -q "$mount" /proc/mounts && return
    echo mounting encfs on $mount
    mkdir -m 0700 -p $mount
    ENCFS6_CONFIG=$BACKUP_ENCFS_CONFIG \
        $ENCFS -S --reverse -i$BACKUP_ENCFS_ENCRYPT_TIMEOUT \
        $clear $mount < $BACKUP_ENCFS_KEY
}

mount_decrypted() {
    local crypt=$1 mount=$2
    mkdir -m 0700 -p $mount
    chmod 700 $mount
    ENCFS6_CONFIG=$BACKUP_ENCFS_CONFIG \
        $ENCFS -S -i$BACKUP_ENCFS_DECRYPT_TIMEOUT \
        $crypt $mount < $BACKUP_ENCFS_KEY
}

mount_sshfs() {
    local sshpath=$1
    local mount=$2
    grep -q "$mount" /proc/mounts && return
    uid=$(id -u)
    gid=$(id -g)
    $SSHFS -o uid=$uid -o gid=$gid "$sshpath" "$mount"
}

is_dir() {
    local dir=${1:-}
    [[ ! "$dir" || -d "$dir" ]]
}

ensure_dir() {
    local prefix=$1
    local dir=${2:-}
    if ! test "$dir"
    then
        tmpdir $prefix
    elif ! test -d "$dir"
    then
        mkdir -p "$dir" && echo "$dir"
    elif test "$(echo "$dir"/*)"
    then
        echo Directory not empty!
        return 1
    else
        echo "$dir"
        return 0
    fi
}

tmpdir() {
    prefix="$1"
    mktemp -d --tmpdir="$BACKUP_TMP" $prefix-XXXXXX
}

unmount() {
    fusername -u "$1"
}

stderr() {
    echo "$@" >&2
}

debug() {
    test "$DEBUG" && stderr "$@" || true
}

fatal() {
    stderr "$@"
    exit 1
}


if test "$0" = "${BASH_SOURCE}"
then
    init "$@"
fi


