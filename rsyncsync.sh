#!/bin/bash

SCRIPT="$0"
DEBUG=${DEBUG:-}
ID_BASE=id
LOCK_BASE=lock
STATE_BASE=state
INDEX_BASE=remotes
LATEST_BASE=latest
NAME="$(basename $0 .sh)"
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
    echo "$SCRIPT SOURCE-DIR [HOST:]BACKUP-PATH"
}

run() {

    get_args "$@" || exit 1
    check_environ

    DOT="$SOURCEDIR/$DOT_NAME"
    LOCAL_INDEX="$DOT/$INDEX_BASE"
    REMOTE_LOCK="$BACKUPROOT/$LOCK_BASE"
    REMOTE_IDFILE="$BACKUPROOT/$ID_BASE"
    REMOTE_LATEST="$BACKUPROOT/$LATEST_BASE"
    REMOTE_STATEFILE="$BACKUPROOT/$STATE_BASE"

    connect
    get_remote_id
    get_remote_state
    get_local_state
    compare_state
    init_dot

    if test "$REMOTE_CHANGED"
    then do_pull
    fi

    if test "$LOCAL_CHANGED"
    then do_push
    fi

    if ! test "$REMOTE_CHANGED" && ! test "$LOCAL_CHANGED"
    then debug 'Nothing to do'
    fi
}

get_args() {
    if test $# -lt 2
    then
        usage; return 1
    fi

    SOURCEDIR=$(readlink -f "$1")
    DESTSPEC="$2"
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
    RSYNC=$(command -v rsync)
    test "$RSYNC" || fatal "rsync not found"

    XDG=${XDG_RUNTIME_DIR:-/tmp}
    RUNDIR=$XDG/$NAME
    SSH=

    if test "$BACKUPHOST"
    then
        SSH=$(command -v ssh)
        test "$SSH" || fatal "ssh not found"
        local opts="-o ControlMaster=auto -o ControlPersist=15m"
        SSH="$SSH -S $RUNDIR/$BACKUPHOST-socket $opts"
        mkdir -p $RUNDIR
    fi
}

connect() {
    if test "$BACKUPHOST"
    then
        $SSH -fN $BACKUPHOST || fatal "unable to contact '$BACKUPHOST'"
    fi
}

get_remote_id() {
    local id=$(echo "$DESTSPEC" | md5)
    local create="mkdir -p $BACKUPROOT"
    local exists="test -f '$REMOTE_IDFILE'"
    local getid="cat $REMOTE_IDFILE || echo $id | tee $REMOTE_IDFILE"
    REMOTE_ID=$(remote_sh "$create && $exists && $getid")
    LOCAL_STATEFILE="$DOT/$STATE_BASE-$REMOTE_ID"
}

get_remote_state() {
    local script="test -f '$REMOTE_STATEFILE' && cat $REMOTE_STATEFILE"
    REMOTE_STATE=$(remote_sh "$script" || true)
}

get_local_state() {
    LOCAL_STATE=$(cat "$LOCAL_STATEFILE" 2>/dev/null || true)
}

get_local_changed() {
    LOCAL_CHANGED=$(find "$SOURCEDIR" -newer "$LOCAL_STATEFILE" \
                    | grep -v /\\$DOT_NAME | head -1)
}

init_dot() {
    mkdir -p "$DOT"
    test -r "$LOCAL_INDEX" || touch "$LOCAL_INDEX"
    if ! grep -q "$REMOTE_ID" "$LOCAL_INDEX"
    then
        echo "$REMOTE_ID" "$DESTSPEC" >> "$LOCAL_INDEX"
    fi
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
        if test -d "$SOURCEDIR" -a "$(echo $SOURCEDIR/*)"
        then
            #fatal "Directory '$SOURCEDIR' not empty, aborting"
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
    debug pulling

    local src="$REMOTE_LATEST"

    if test "$BACKUPHOST"
    then
        src="$BACKUPHOST:$src"
    fi

    if test "$LOCAL_CHANGED"
    then
        pull_dirty "$src"
    else
        pull_clean "$src"
    fi
    record_state "$REMOTE_STATE"
}

pull_clean() {
    local dst="$SOURCEDIR"
    do_rsync -v --delete "$src/" "$dst"
    debug "clean pull"
}

pull_dirty() {
    local date=$(date_stamp)
    local tmp=$(mktemp -d --tmpdir=$DOT)
    local dst="$SOURCEDIR"

    do_rsync --delete --backup --backup-dir="$tmp" "$src/" "$dst"
    if test "$(find_conflicts "$tmp" | head -1)"
    then
        warn_conflicts "$date" "$tmp"
        local conflict_path="$SOURCEDIR/$CONFLICT_BASE"
        mkdir -p "$conflict_path"
        mv "$tmp" "$conflict_path/$date"
    else
        rmdir "$tmp"
        debug "no conflicts"
        LOCAL_CHANGED=
    fi
}

do_push() {
    debug "pushing to remote"
    local new_stamp=$(date_stamp)
    pre_push || fatal "pre-push failed"
    rsync_push
    post_push
}

pre_push() {
    local touch="mkdir $BACKUPROOT/$new_stamp"
    local lock="ln -s $new_stamp $REMOTE_LOCK"
    local test="test -L '$REMOTE_LATEST'"
    HAS_LATEST=$(remote_sh "$touch && $lock && $test" \
                    && echo 1 || true)
}

rsync_push() {
    local dst="$BACKUPROOT/$new_stamp"
    if test "$BACKUPHOST"
    then
        dst="$BACKUPHOST:$dst"
    fi
    local link=
    if test -z "$HAS_LATEST"
    then
        stderr "init remote '$BACKUPROOT'"
    else
        link=--link-dest=../$LATEST_BASE
    fi
    do_rsync $link "$SOURCEDIR/" "$dst"

}

post_push() {
    local state=$(new_state)
    local relink="rm -f $REMOTE_LATEST && ln -s $new_stamp $REMOTE_LATEST"
    local unlock="rm $REMOTE_LOCK"
    local record="echo '$state' > $REMOTE_STATEFILE"
    remote_sh "$relink && $unlock && $record"
    record_state "$state"
}

record_state() {
    echo "$1" > "$LOCAL_STATEFILE"
}

remote_sh() {
    if test "$BACKUPHOST"
    then
        $SSH $BACKUPHOST "$@"
    else
        eval "$@"
    fi
}

do_rsync() {
    if test "$BACKUPHOST"
    then
        $RSYNC -e "$SSH" -a --exclude /$DOT_NAME "$@"
    else
        $RSYNC -a --exclude /$DOT_NAME "$@"
    fi
}

find_conflicts() {
    local path="$1"
    local name=$(basename "$path")
    (cd "$path/.." && find $name ! -path $name)
}

warn_conflicts() {
    local date="$1"
    local path="$2"
    local name=$(basename "$path")
    {
        echo
        echo "*** WARNING ***"
        echo
        echo "(maybe) changed local files replaced by remote"
        echo
        echo $CONFLICT_BASE/$date
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

error() {
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

