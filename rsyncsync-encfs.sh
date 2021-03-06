#!/bin/bash

SELF=$(readlink -f $0)
RSYNCSYNC=$(dirname $SELF)/rsyncsync.sh
DEBUG=${DEBUG:-}

: ${BACKUP_ENCFS_ENCRYPT_TIMEOUT:=15}
: ${BACKUP_ENCFS_DECRYPT_TIMEOUT:=5}


init() {
    set -eu
    shopt -s nullglob dotglob
    dispatch "$@"
}

dispatch() {
    check_environ
    if (($#))
    then
        cmd=${1//-/_}
        shift
        if [[ $(type -t "cmd_$cmd") = function ]]
        then
            cmd_$cmd "$@"
            return 0
        fi
    fi
    usage
    exit 1
}

check_environ() {
    set +u
    test "$SSH"     || SSH=$(type -p ssh || true)
    test "$SSHFS"   || SSHFS=$(type -p sshfs || true)
    test "$ENCFS"   || ENCFS=$(type -p encfs || true)
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
    cd $HOME
}

usage() {
    echo Usage:
    echo "$0 COMMAND"
    echo
    echo COMMAND:
    local funcs=$(declare -f | grep ^cmd_ | cut -d' ' -f1)
    for cmd in $funcs
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

cmd_config_repeat() {
    repeat_targets_from_config "$@"
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
    local x=
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
    local encfs= sshfs= s=
    s=$(mount_history_from_config "$id" "$num")
    local var=BACKUP_SOURCE_$id
    local source=${!var:-}
    echo diff -urq "$source" "$encfs"/latest
    echo fusermount -u $encfs
    echo fusermount -u $sshfs
}

purge_history_from_config() {
    local id="${1:-}" num="${2:-}"
    local encfs= sshfs= s=
    local var=BACKUP_TARGET_$id
    local target=${!var:-}
    test "$target" || fatal "$var unset"
    local target="${BACKUP_TARGETS[num]}/$target"
    local keep=${BACKUP_KEEP:-100}
    local crypt=$target
    s=$(mount_history_from_config "$id" "$num")
    eval "$s"
    if [[ "$sshfs" ]]
    then
        crypt=$sshfs
    fi
    purge_history
    sleep 1
    fusermount -u $encfs
    test "$sshfs" && fusermount -u $sshfs
}

purge_history() {
    echo purge $keep "$target" "$encfs" "$sshfs"

    local all=("$encfs"/2*)
    local count=${#all[@]}
    ((count<=keep)) && return 0
    local crypt_rm=()
    local crypt_d= clear_d= inode=
    local error=0 i=0
    local keep_count=0
    local purge_count=0

    for ((i=0; i<count; ++i))
    do
        clear_d=${all[i]}
        if (( i % 2 == 1 || i > count / 2 ))
        then
            echo "  ${clear_d##*/}"
            ((++keep_count))
        else
            inode=$(stat -c%i $clear_d)
            crypt_d=$(find $crypt -maxdepth 1 -type d -inum $inode)
            if ! test "$crypt_d"
            then
                echo "missing $clear_d -> $crypt_d"
                error=1
            else
                echo "- ${clear_d##*/}"
                crypt_rm+=($crypt_d)
                ((++purge_count))
            fi
        fi
    done
    if ((error))
    then
        echo "not proceeding due to errors"
        return 1
    fi
    echo "total: $count keep: $keep_count purge: $purge_count"
    local host=
    if [[ "$target" = *:* ]]
    then
        host=${target%%:*}
    fi
    local root=${target##*:}
    local script='test -d "$d" && chmod -R +w "$d"'
          script+=' && echo "rm $d" && rm -rf -- "$d"'
    if [ "$host" ]
    then
        local sshcmd="f() { for d; do $script ; done; }; f "
        for crypt_d in "${crypt_rm[@]}"
        do
            printf "'$root/$(basename $crypt_d)'\0"
        done | xargs -r0 -s 65535 ssh $host "$sshcmd"
    else
        eval "f() { local d=\$1; $script; }"
        for crypt_d in "${crypt_rm[@]}"
        do
            f "$root/$(basename $crypt_d)"
        done
    fi

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
        sync_one "$source" "$target"
        [ $? -eq 0 ] && return 0
        errors+=("$output")
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
    elif [[ ! -d "$crypt" ]]
    then
        echo "$crypt" does not exist >&2
        return 1
    fi

    mount=$(ensure_dir clear $mount)
    mount_decrypted "$crypt" "$mount"
    echo "encfs='$mount'"
}

cmd_encrypt() {
    local clear=${1:-} mount=${2:-}
    clear=$(readlink -f "$clear")
    [[ -d "$clear" ]]  || {
        echo 'require existing directory' >&2
        exit 1
    }
    mount=$(ensure_dir crypt $mount)
    mount_encrypted "$clear" "$mount"
    echo "encfs='$mount'"
}

cmd_sshfs() {
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

repeat_targets_from_config() {
    local id="${1:-}" var=
    test "$id" || fatal "missing ID arg"
    local delay=${2:-1}

#    if ((delay > 1))
#    then
#        # random jitter so multiple 'at's don't hit the
#        # server at the same minute
#        case $(date +%S) in
#            00|01|02)
#            sleep $(($RANDOM * 2 / 4321 + 1));;
#        esac
#    fi

    var=BACKUP_SOURCE_$id
    local source=${!var:-}
    test "$source" || fatal "$var unset"

    local lock=$source/.rsyncsync/lock.schedule
    if [ -r $lock ]
    then
        echo locked
        exit 1
    fi

    # necessary?
    #exec 200>$lock
    #flock -n 200 || fatal "failed obtaining lock"

    unschedule

    local status=$source/.rsyncsync/status
    export RSYNCSYNC_WRITE_STATUS=$status
    try_targets_from_config $id

    if [ "$(cat $status)" = 'no change' ]
    then
        ((delay *= 2))
        ((delay > 60 )) && delay=60 || true
    else
        delay=1
    fi
    reschedule
    rm -f $lock
}

unschedule() {
    local job
    for job in $(atq | grep -v = | cut -f1)
    do
        if at -c $job | tail -1 | grep -q "$SELF.config-repeat.$id"
        then
            echo unschedule job $job
            atrm $job
        fi
    done
}

reschedule() {
    local out= rc=
    local cmd="$SELF config-repeat $id $delay"
    out=$(echo -n "$cmd" | at "now + $delay min" 2>&1)
    rc=$?
    if (( $rc != 0 ))
    then
        echo "$out" >&2
        return $rc
    fi
    return 0
}

get_args() {
    i=1
    local _names=()
    while [ "$1" != '--' ]
    do
        _names+=($1)
        shift
    done
    shift
    local _name
    for _name in ${_names[@]}
    do
        eval "$_name=\${1:-}"
        test "${!_name}" || fatal "missing arg ${_name^^}"
        shift
    done
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


