#!/bin/bash

DEBUG=${DEBUG:-}
ID_BASE=id
LOCK_BASE=lock
STATE_BASE=state
INDEX_BASE=remotes
LATEST_BASE=latest

SCRIPT=$BASH_SOURCE
NAME=$(basename "$SCRIPT" .sh)
DOT_NAME=.$NAME
CONFLICT_BASE="_${NAME}_conflicts"
DATE_FORMAT="${DATE_FORMAT:-%Y%m%d_%H%M%S.%N}"

init() {
    set -eu
    #set -Eeu
    #set -o pipefail
    #trap 'error $?' ERR
    #trap '' PIPE
    shopt -s nullglob dotglob
    run "$@"
    exit 0
}

usage() {
    echo Usage:
    echo "$SCRIPT SOURCE-DIR [CRYPT] [HOST:]BACKUP-PATH"
}

run() {

    get_args "$@" || fatal 'usage'
    check_environ

    DOT=$SOURCEDIR/$DOT_NAME
    LOCAL_LOCK=$DOT/$LOCK_BASE
    REMOTE_INDEX=$DOT/$INDEX_BASE
    REMOTE_LOCK=$BACKUPROOT/$LOCK_BASE
    REMOTE_IDFILE=$BACKUPROOT/$ID_BASE
    REMOTE_STATEFILE=$BACKUPROOT/$STATE_BASE

    test "${TEST:-}" || lock_local
    connect
    get_remote_id
    get_remote_state
    get_local_state
    compare_state
    init_dot

    RESULT=

    if test "$REMOTE_CHANGED"
    then do_pull
    fi

    # pull can detect a spurious local change
    # and disable subsequent push
    if test "$LOCAL_CHANGED"
    then do_push
    fi

    if ! test "$REMOTE_CHANGED" && ! test "$LOCAL_CHANGED"
    then : ${RESULT:='no change'}
    fi

    result "${RESULT:-'unknown error'}"
}

get_args() {
    if test $# -lt 2
    then
        usage; return 1
    fi

    SOURCEDIR=$(readlink -f "$1")
    CRYPT=

    if test $# -eq 3
    then
        CRYPT=$2
        if ! has_crypt
        then
            usage
            echo "directory '$CRYPT' does not exist"
            return 1
        fi
        shift
    fi

    DESTSPEC=$2
    BACKUPROOT=${DESTSPEC#*:}
    BACKUPHOST=""

    if test -z "${DESTSPEC##*:*}"
    then
        BACKUPROOT=${BACKUPROOT:-.}
        BACKUPHOST=${DESTSPEC%%:*}
        test "$BACKUPHOST" || { usage; return 1; }
    fi
}

check_environ() {
    RSYNC=$(command -v rsync || true)
    test "$RSYNC" || fatal "rsync not found"

    if test "$BACKUPHOST"
    then
        test "${SSH:-}" || SSH=$(command -v ssh || true)
        test "$SSH" || fatal "ssh not found"
    fi
}

has_crypt() {
    # TODO: more robust check?
    test "$CRYPT" && test -d "$CRYPT"
}

lock_local() {
    test -d "$DOT" || return 0
    exec 200>$LOCAL_LOCK
    flock -n 200 || fatal "failed obtaining lock"
}

connect() {
    if test "$BACKUPHOST"
    then
        # assumes ControlMaster for performance
        local opt='-o PreferredAuthentications=publickey'
        $SSH $opt $BACKUPHOST true 2>/dev/null ||
            fatal "unable to contact '$BACKUPHOST'"
    fi
}

get_remote_id() {
    local id=$(echo "$DESTSPEC" | md5)
    local create="mkdir -p -- '$BACKUPROOT'"
    local exists="test -f '$REMOTE_IDFILE'"
    local getid="cat -- '$REMOTE_IDFILE'"
    local putid="echo '$id' | tee -- '$REMOTE_IDFILE'"
    REMOTE_ID=$(remote_sh "$create && $exists && $getid || $putid")
    LOCAL_STATEFILE=$DOT/$STATE_BASE-$REMOTE_ID
}

get_remote_state() {
    local script="test -f '$REMOTE_STATEFILE' && cat -- '$REMOTE_STATEFILE'"
    REMOTE_STATE=$(remote_sh "$script" || true)
}

get_local_state() {
    LOCAL_STATE=$(cat "$LOCAL_STATEFILE" 2>/dev/null || true)
}

get_local_changed() {
    LOCAL_CHANGED=$(find "$SOURCEDIR" -newer "$LOCAL_STATEFILE"  |
                        grep -v "/\\$DOT_NAME" | head -1)
}

init_dot() {
    mkdir -p "$DOT"
    test -r "$REMOTE_INDEX" || touch "$REMOTE_INDEX"
    if ! grep -q "$REMOTE_ID" "$REMOTE_INDEX"
    then
        echo "$REMOTE_ID" "$DESTSPEC" >> "$REMOTE_INDEX"
    fi
}

get_crypt_name() {
    local inode=$(stat -c%i "$1")
    local crypt=$(find "$CRYPT" -maxdepth 3 -inum $inode)
    test "$crypt" && basename "$crypt"
}

tmp_crypt_name() {
    local name=$1
    if ! test -f "$name"
    then
        :> "$DOT/$name"
    fi
    local crypt=$(get_crypt_name "$DOT/$name")
    # keep 'latest' for reuse in later step; timing bug in encfs ?
    if test "$name" != "$LATEST_BASE"
    then
        rm -f "$DOT/$name"
    fi
    echo "$crypt"
}

compare_state() {
    if test -z "$REMOTE_STATE"
    then
        # init remote and force push
        LOCAL_STATE=
        LOCAL_CHANGED=1

    elif test -z "$LOCAL_STATE"
    then
        # have remote state, not local
        # abort if source is not empty
        if test -d "$SOURCEDIR" -a "$(echo "$SOURCEDIR"/*)"
        then
            fatal "'$SOURCEDIR' exists and is not empty, aborting"
        fi
        LOCAL_CHANGED=

    elif test ! -f "$LOCAL_STATEFILE"
    then
        LOCAL_CHANGED=1

    else
        get_local_changed
    fi

    REMOTE_CHANGED=
    if test "$LOCAL_STATE" != "$REMOTE_STATE"
    then
        REMOTE_CHANGED=1
    fi
}

do_pull() {
    debug "pulling from '$DESTSPEC'"

    local pull_src=$LATEST_BASE
    local pull_dst=$SOURCEDIR
    local exclude=$DOT_NAME
    local pull_opts=() pull_tmp=

    if has_crypt
    then
        pull_src=$(tmp_crypt_name "$LATEST_BASE")
        pull_dst=$CRYPT
        exclude=$(get_crypt_name "$DOT")
        # use temp-dir outside encfs mount because encfs disallows writing
        # arbitrary files to an encfs reverse mount
        pull_tmp=$(mktemp -d --tmpdir="$DOT" crypt-XXXXXXXX)
        mkdir -p "$pull_tmp"
        pull_opts=(--temp-dir "$pull_tmp")
    fi

    pull_src=$BACKUPROOT/$pull_src

    if test "$BACKUPHOST"
    then
        pull_src=$BACKUPHOST:$pull_src
    fi

    pull_opts+=(--exclude "/$exclude")

    if test "$LOCAL_CHANGED"
    then
        pull_dirty
    else
        pull_clean
    fi
    test "$pull_tmp" && rm -rf "$pull_tmp"
    record_state "$REMOTE_STATE"
}

pull_clean() {
    do_rsync "${pull_opts[@]}" --delete "$pull_src/" "$pull_dst"
    RESULT='clean pull'
}

pull_dirty() {
    local conflict_tmp=$(mktemp -d --tmpdir="$DOT" conflict-XXXXXXXX)
    local rsync_backup=$conflict_tmp

    if has_crypt
    then
        dot_crypt=$(get_crypt_name "$DOT")
        tmp_crypt=$(get_crypt_name "$conflict_tmp")
        rsync_backup=$CRYPT/$dot_crypt/$tmp_crypt
    fi

    # optimisation option: assume older files have not been updated and
    # overwrite with newer versions. this avoids backing up such old files
    # that have changed remotely
    if test "${RSYNCSYNC_MERGE_DISCARD_OLD:-}"
    then
        do_rsync "${pull_opts[@]}"  \
            --update                \
            "$pull_src/" "$pull_dst"
    fi

    # now back up local changes;
    # files deleted locally will reappear from remote
    do_rsync "${pull_opts[@]}"  \
        --delete --backup       \
        --backup-dir "$rsync_backup" \
        "$pull_src/" "$pull_dst"

    # rsync sometimes places empty dirs in the backup;
    # remove them so we only have the salient conflict files
    find "$conflict_tmp" -depth -type d -delete \
        2>/dev/null || true

    if test -d "$conflict_tmp"
    then
        local date=$(date_stamp)
        warn_conflicts "$date" "$conflict_tmp"
        local conflict_path=$SOURCEDIR/$CONFLICT_BASE
        mkdir -p "$conflict_path"
        mv "$conflict_tmp" "$conflict_path/$date"
        RESULT="conflicts in $conflict_path/$date"
    elif test "${RSYNCSYNC_MERGE_DISCARD_OLD:-}"
    then
        RESULT='merge'
    else
        # signal nothing to push
        LOCAL_CHANGED=
        RESULT='clean merge'
    fi
}

do_push() {
    debug "pushing to '$DESTSPEC'"
    local backup_base=$(date_stamp)
    local push_src=$SOURCEDIR
    local push_latest=$LATEST_BASE
    if has_crypt
    then
        push_src=$CRYPT
        push_latest=
        push_latest=$(tmp_crypt_name "$LATEST_BASE")
        backup_base=$(tmp_crypt_name "$backup_base")
        test "$push_latest"
    fi

    local push_dst=$BACKUPROOT/$backup_base
    if test "$BACKUPHOST"
    then
        push_dst=$BACKUPHOST:$push_dst
    fi
    pre_push || fatal "pre-push failed"
    rsync_push
    post_push
    test "$RESULT" || RESULT="push to $DESTSPEC"
}

pre_push() {
    local mkdir="mkdir -- '$BACKUPROOT/$backup_base'"
    local lock="mkdir -- '$REMOTE_LOCK'"
    local test="{ test -L '$BACKUPROOT/$push_latest' && echo 1 || true; }"
    HAS_LATEST=$(remote_sh "$mkdir && $test && $lock")
}

rsync_push() {
    local dst=$BACKUPROOT/$backup_base
    if test "$BACKUPHOST"
    then
        dst=$BACKUPHOST:$dst
    fi
    local link=
    if test -z "$HAS_LATEST"
    then
        stderr "init remote '$BACKUPROOT'"
    else
        link=--link-dest=../$push_latest
    fi
    do_rsync $link "$push_src/" "$push_dst"

}

post_push() {
    local state=$(new_state)
    local rmlink="rm -f -- '$BACKUPROOT/$push_latest'"
    local relink="ln -s -- '$backup_base' '$BACKUPROOT/$push_latest'"
    local unlock="rmdir -- '$REMOTE_LOCK'"
    local record="echo '$state' > '$REMOTE_STATEFILE'"
    remote_sh "$rmlink && $relink && $unlock && $record"
    record_state "$state"
}

record_state() {
    echo "$1" > "$LOCAL_STATEFILE"
}

remote_sh() {
    #debug remote_sh "$@"
    if test "$BACKUPHOST"
    then
        $SSH $BACKUPHOST "$@"
    else
        eval "$@"
    fi
}

do_rsync() {
    #debug "$RSYNC -a" "$@"
    if test "$BACKUPHOST"
    then
        $RSYNC -e "$SSH" -a "$@"
    else
        $RSYNC -a "$@"
    fi
}

find_conflicts() {
    local path=$1
    local name=$(basename "$path")
    (cd "$path/.." && find "$name" ! -path "$name")
}

warn_conflicts() {
    local date=$1
    local path=$2
    local name=$(basename "$path")
    {
        echo
        echo "*** WARNING ***"
        echo
        echo "(maybe) changed local files replaced by remote"
        echo
        echo "$CONFLICT_BASE/$date"
        find_conflicts "$path" | sed "s/^$name\//  /" | sort
        echo
    } >&2
}

date_stamp() {
    date "+$DATE_FORMAT"
}

new_state() {
    date +%s.%N | md5
}

md5() {
    md5sum | cut -c1-32
}

result() {
    debug "$@"
    local f=${RSYNCSYNC_WRITE_STATUS:-}
    if test "$f"
    then
        echo "$@" > "$f"
    fi
}

debug() {
    test "$DEBUG" && stderr "$@" || true
}

__unused__error() {
    trap - ERR
    let i=0 status=$1
    {
        echo "Error: $status"
        while caller $i
        do
            ((i++))
        done | sed 's/^/ /' | tac
    } >&2
    exit $status
}

stderr() {
    echo "$@" >&2
}

fatal() {
    stderr "${1:-unknown}"
    result "ERROR: ${1:-unknown}"
    exit 1
}

if test "$0" = "${BASH_SOURCE}"
then
    init "$@"
fi

