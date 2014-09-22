#!/bin/bash


HERE=$(dirname "$BASH_SOURCE")
NAME=rsyncsync
DOT=.$NAME
CONFLICTS=_${NAME}_conflicts
R=$(readlink -f $HERE/$NAME.sh)

HELLO=$(date)

# preliminaries

util sync difftree diffstat diffhash



write_state() {
    echo "$HELLO" > test
}

access_given_state() {
    # should have HELLO from write_state
    given write_state
    test -d "$GIVEN"
    test "$(cat "$GIVEN"/test)" = "$HELLO"
    test "$(cd "$GIVEN" && ls)" = "$(cd "$THIS" && ls)"
}

treestat_works() {
    mkdir test
    echo "$HELLO" > test/file
    # rather loose assertion
    _treestat test | grep -q file
}

treehash_works() {
    mkdir test
    hash=$(echo "$HELLO" | md5sum | cut -c1-32)
    echo "$HELLO" > test/file
    _treehash test | grep -q "$hash.*/file"
}

difftree_works() {
    # compare tree to self returns true
    given treehash_works
    date > date-file
    difftree "$THIS" "$THIS"
}

dir_empty() {
    # should be in an empty dir
    test -z "$(shopt -s nullglob dotglob;  echo *)"
}

difftree_works_with_empty_dir() {
    given dir_empty
    difftree "$GIVEN" "$THIS"
}

difftree_works_different_number_parent_links() {
    given difftree_works_with_empty_dir
    mkdir -p x/1 x/2 x/3
    rsync -aH "$GIVEN/" x/1
    difftree "$GIVEN" x/1
}

given_states_identical() {
    given difftree_works
    difftree "$GIVEN" "$THIS"
}

this_state_isolated() {
    given given_states_identical
    chmod 700 date-file
    ! difftree "$GIVEN" "$THIS"
}


# start testing!

no_args_shows_usage() {
    sync | grep -q Usage
}

one_arg_shows_usage() {
    sync _ | grep -q Usage
}


local_1() {
    # creates a local directory of working files
    mkdir -p local1/{a,b,c}/{1,2,3}
    for d in `find local1 -type d`
    do
        echo "$RANDOM $d" > $d/stuff
    done
}

local_untracked() {
    # remove sync state from local
    given local_1
    rm -rf local1/$DOT
}

local_empty_remote_empty() {
    # should init local and init remote
    sync local1 backup1
    test -d local1/$DOT
    test -L backup1/latest
    difftree local1 backup1/latest
}

local_untracked_remote_empty() {
    # should re-init local and remote
    given local_untracked
    rm -rf local1/$DOT
    sync local1 backup1
    test -d local1/$DOT
    test -L backup1/latest
    difftree local1 backup1/latest
}

local_unchanged_by_backup() {
    given local_untracked
    sync local1 backup1
    difftree $GIVEN/local1 local1
}

local_backed_up() {
    given local_unchanged_by_backup
    difftree local1 backup1/latest
}

remote_untracked() {
    given local_backed_up
    rm -rf backup1/{id,state,latest}
}

local_empty_remote_untracked() {
    # re-init local and remote
    given remote_untracked
    rm -rf local1
    sync local1 backup1
    test -d local1/$DOT
    test -L backup1/latest
    difftree local1 backup1/latest
}

local_untracked_remote_untracked() {
    # re-init local and remote
    given remote_untracked
    rm -rf local1/$DOT
    sync local1 backup1
    test -d local1/$DOT
    test -L backup1/latest
    difftree local1 backup1/latest
}

local_tracked_remote_empty() {
    # re-init remote
    given local_backed_up
    rm -rf backup1
    sync local1 backup1
    test -L backup1/latest
    difftree local1 backup1/latest
}

local_tracked_preserves_remote_id() {
    # can use any spelling for remote
    given local_backed_up
    sync local1 ./backup1/
    difftree "$GIVEN" "$THIS"
    sync local1 ./backup1/././
    difftree "$GIVEN" "$THIS"
}

local_tracked_remote_untracked() {
    # re-init remote
    given remote_untracked
    sync local1 backup1
    test -L backup1/latest
    test -f backup1/state
    diffhash local1 backup1/latest
}

local_empty_remote_tracked() {
    # should pull (restore) from remote
    given local_backed_up
    rm -rf local1
    sync local1 backup1
    difftree $GIVEN/local1 local1
    difftree $GIVEN/backup1 backup1
}

local_untracked_remote_tracked() {
    # should abort and do nothing
    given local_backed_up
    rm -rf local1/$DOT/*
    if sync local1 backup1
    then exit 1
    fi
    difftree $GIVEN $THIS
}

local_unchanged_remote_unchanged() {
    # does nothing
    given local_backed_up
    sync local1 backup1
    difftree $GIVEN $THIS
}

_modify() {
    arg="$1"
    for f in `find "$arg"/* -type f`
    do
        echo "modifying $f"
        sleep 0.5
        date +%s.%N >> "$f"
        return
    done
}

local_changed_remote_unchanged() {
    given local_backed_up
    _modify local1
    previous=$(readlink -f backup1/latest)
    sync local1 backup1
    diffhash local1 backup1/latest
    diffhash "$GIVEN"/local1 "$previous"
}

local_2() {
    given local_backed_up
    sync local2 backup1
    difftree local1 local2
}

local_2_modified() {
    given local_2
    _modify local2
    ! diffhash $GIVEN/local2 local2
}

remote_changed() {
    given local_2_modified
    sync local2 backup1
    diffhash local2 backup1/latest
}

local_unchanged_remote_changed() {
    # should pull changes to local1
    # and leave backup1 unchanged
    given remote_changed
    sync local1 backup1
    difftree local1 local2
    difftree $GIVEN/backup1 backup1
}

local_no_conflicts() {
    given local_unchanged_remote_changed
    ! test -d local1/$CONFLICTS
}

local_changed_concurrently() {
    given remote_changed
    mark=$(date +%s.%N)
    echo "$mark" > local1/stuff
}

local_preserves_conflicting_changes() {
    # local changed, remote changed
    # should back up local changes
    # and push to server
    given local_changed_concurrently
    sync local1 backup1
    test -d local1/$CONFLICTS
    cd local1/$CONFLICTS/*
    for f in `find -type f`
    do
        diff -u $f $GIVEN/local1/$f
    done
}

local_conflicts_propagate() {
    given local_preserves_conflicting_changes
    diffhash local1 backup1/latest
    sync local2 backup1
    difftree local1 local2
}




sync() {
    $R "$@"
}


_treestat() {
    (cd "$1" && find -print0 | xargs -r0 ls -ld) \
        | grep -v /\\$DOT | grep -v \\.$
}

_treehash() {
    (cd "$1" && find -type f -print0 | sort -z | xargs -r0 md5sum) \
        | grep -v /\\$DOT
}

diffstat() {
    diff <(_treestat "$1") <(_treestat "$2")
}

diffhash() {
    diff <(_treehash "$1") <(_treehash "$2")
}

difftree() {
    diffstat "$1" "$2" && diffhash "$1" "$2"
}

_rmtree() {
    # assert arg is under tmp dir
    test "${1/$ROUNDUP_TMP/}" = "$1" || return 1
    test -d "$1" && chmod -R +w "$1" && rm -rf "$1"
}
