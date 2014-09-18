#!/bin/bash

set -eu
set -o pipefail

shopt -s nullglob dotglob

SCRIPT="$0"
NAME="$(basename $0 .sh)"
DOTNAME=.$NAME
DATE_FORMAT="%Y%m%d_%H%M%S"
DEBUG=${DEBUG:-}


usage() {
    { 
        echo Usage:
        echo "$SCRIPT SOURCE-DIR [HOST:]BACKUP-PATH"
    } >&2
}

main() {
    trap 'error $?' ERR

    get_args "$@"
    check_environ

    DOTDIR="$SOURCEDIR/$DOTNAME"

    LATEST="$BACKUPROOT/latest"
    LOCK="$BACKUPROOT/lock"
    REMOTE_STATEFILE="$BACKUPROOT/state"
    REMOTE_IDFILE="$BACKUPROOT/id"
    CONFLICT_BASE="_${NAME}_conflicts"
    LOCAL_INDEX="$DOTDIR/remotes"

    connect

    REMOTE_ID=$(get_remote_id)
    LOCAL_STATEFILE="$DOTDIR/state-$REMOTE_ID"
    REMOTE_STATE=$(get_remote_state)
    local local_state=$(get_local_state)

    if [[ "$REMOTE_STATE" = "" ]]
    then
        # init remote, force push
        local_state=
        LOCAL_CHANGED=1

    elif [[ "$local_state" = "" ]]
    then
        # have remote state, not local
        if [[ -d "$SOURCEDIR" ]]
        then
            fatal "Directory '$SOURCEDIR' exists, aborting"
        fi
        LOCAL_CHANGED=

    else
        LOCAL_CHANGED=$(has_local_changes)
    fi

    mkdir -p "$DOTDIR"

    if [[ "$REMOTE_STATE" != "$local_state" ]]
    then
        do_pull

    elif [[ "$LOCAL_CHANGED" ]]
    then
        do_push
    
    else
        debug "nothing to do"
    fi

}

get_args() {
    if [[ $# -lt 2 ]]
    then
        usage && exit 1
    fi

    SOURCEDIR=$(readlink -f "$1")
    DESTSPEC="$2"
    BACKUPROOT=${DESTSPEC#*:}
    BACKUPHOST=""

    if [[ "${DESTSPEC##*:*}" = "" ]]
    then
        BACKUPROOT=${BACKUPROOT:-.}
        BACKUPHOST=${DESTSPEC%%:*}
        [[ "$BACKUPHOST" ]] || { usage && exit 1; }
    fi
}

check_environ() {
    RSYNC=$(command -v rsync)
    [[ "$RSYNC" ]]  || fatal "rsync not found"

    XDG=${XDG_RUNTIME_DIR:-/tmp}
    RUNDIR=$XDG/$NAME
    SSH=

    if [[ "$BACKUPHOST" ]]
    then
        SSH=$(command -v ssh)
        [[ "$SSH" ]]  || fatal "ssh not found"
        local opts="-o ControlMaster=auto -o ControlPersist=15m"
        SSH="$SSH -S $RUNDIR/socket $opts"
        mkdir -p $RUNDIR
    fi
}

connect() {
    if [[ "$BACKUPHOST" ]]
    then
        $SSH -fN $BACKUPHOST || fatal "unable to contact '$BACKUPHOST'"
    fi
}

get_remote_id() {
    local file="$REMOTE_IDFILE"
    local id=$(echo "$DESTSPEC" | md5)
    local create="mkdir -p $BACKUPROOT"
    remote_sh "$create && test -f '$file' && cat $file || echo $id | tee $file"
}

get_remote_state() {
    local file="$REMOTE_STATEFILE"
    remote_sh "test -f '$file' && cat $file || true"
}

get_local_state() {
    if [[ -f "$LOCAL_STATEFILE" ]]
    then
        cat "$LOCAL_STATEFILE"
    fi
}

has_local_changes() {
    if [[ ! -f "$LOCAL_STATEFILE" ]]
    then
        echo 1
        return
    fi
    new=$(find "$SOURCEDIR" -newer "$LOCAL_STATEFILE" \
            | grep -v /\\$DOTNAME | head -1)
    if [[ "$new" ]]
    then
        echo 1
    fi
}

do_pull() {
    debug pulling

    local dst="$SOURCEDIR"
    local src="$LATEST"

    if [[ "$BACKUPHOST" ]]
    then
        src="$BACKUPHOST:$src"
    fi

    if [[ "$LOCAL_CHANGED" ]]
    then
        local date=$(date_stamp)
        local tmp=$(mktemp -d --tmpdir=$DOTDIR)

        do_rsync --delete --backup --backup-dir="$tmp" "$src/" "$dst"
        if [[ "$(find_conflicts "$tmp" | head -1)" ]]
        then
            warn_conflicts "$date" "$tmp"
            local conflict_path="$SOURCEDIR/$CONFLICT_BASE"
            mkdir -p "$conflict_path"
            mv "$tmp" "$conflict_path/$date"
            do_push
            return
        else
            rmdir "$tmp"
            debug "no conflicts"
        fi
    else
        do_rsync --delete "$src/" "$dst"
        debug "clean pull"
    fi
    record_state "$REMOTE_STATE"
}

do_push() {
    debug "pushing to remote"
    local new=$(date_stamp)
    pre_push "$new" || fatal "pre-push failed"
    rsync_push "$new"
    post_push "$new"
}

pre_push() {
    local new="$1"
    local lock="ln -s $new $LOCK"
    local touch="mkdir $BACKUPROOT/$new"
    local test="test -L '$LATEST' && echo 1 || true"
    HAS_LATEST=$(remote_sh "$touch && $lock && $test")
}

rsync_push() {
    local new="$1"
    local dst="$BACKUPROOT/$new"
    if [[ "$BACKUPHOST" ]]
    then
        dst="$BACKUPHOST:$dst"
    fi
    local link=
    if [[ "$HAS_LATEST" = "" ]]
    then
        stderr "init remote '$BACKUPROOT'"
    else
        link=--link-dest=../latest
    fi
    do_rsync $link "$SOURCEDIR/" "$dst"

}

post_push() {
    local new="$1"
    local state=$(new_state)
    local relink="rm -f $LATEST && ln -s $new $LATEST"
    local unlock="rm $LOCK"
    local record="echo '$state' > $REMOTE_STATEFILE"
    remote_sh "$relink && $unlock && $record"
    record_state "$state"
}

record_state() {
    touch "$LOCAL_INDEX"
    if ! grep -q "$REMOTE_ID" "$LOCAL_INDEX"
    then
        echo "$REMOTE_ID" "$DESTSPEC" >> "$LOCAL_INDEX"
    fi
    echo "$1" > "$LOCAL_STATEFILE"
}

remote_sh() {
    if [[ "$BACKUPHOST" ]]
    then
        $SSH $BACKUPHOST "$@"
    else
        eval "$@"
    fi
}

do_rsync() {
    if [[ "$BACKUPHOST" ]]
    then
        $RSYNC -e "$SSH" -a --exclude /$DOTNAME "$@"
    else
        $RSYNC -a --exclude /$DOTNAME "$@"
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
        find_conflicts "$path" | sed "s/^$name\//  /" | sort
        echo
        echo backups in $CONFLICT_BASE/$date
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
    [[ "$DEBUG" ]] && stderr "$@" || true
}

fatal() {
    stderr "$@"
    exit 1
}


main "$@"
exit 0

