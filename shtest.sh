#!/bin/bash

ROUNDUP_TEST_SUFFIX=.test.sh
ROUNDUP_TEST_REGEXP='^[a-zA-Z][a-zA-Z0-9_-]\+'

roundup_run() {

    set -Ee

    local files="$@"
    local suffix=$ROUNDUP_TEST_SUFFIX

    if test "$#" -eq "0"
    then
        files=*$suffix
    fi

    local check='✔' cross='✘' sigma='Σ'
    local red= grn= mag= clr=

    if test -t 1
    then
        red=$'\033[31m'
        grn=$'\033[32m'
        yel=$'\033[33m'
        mag=$'\033[35m'
        clr=$'\033[m'
    fi

    ROUNDUP_TMP=$(mktemp -d --tmpdir roundup.XXXXXXXXXX)
    mkdir -p "$ROUNDUP_TMP"
    #trap "rm -rf '$ROUNDUP_TMP'" EXIT
    trap 'rc=$?; set +x; set -o | grep -q "errexit.*on" && exit $rc' ERR

    passed=0 failed=0

    for ROUNDUP_FILE in $files
    do
        roundup_run_file
    done

    roundup_summarize
    return $failed
}

roundup_run_file() {
    local desc=$(basename "$ROUNDUP_FILE")
    local utils=

    describe() { desc="$*"; }
    util() { utils=" $utils $* "; }

    local _given rc

    given() {
        ( test -z "$_given" && eval "__given_$1") &>/dev/null
        {
            rc=$? _given="$1"
            test -d "$ROUNDUP_TMP/$1"
            GIVEN="$ROUNDUP_TMP/$1"
            rsync -aH "$GIVEN/" "$THIS/"
        } &> /dev/null
        return $rc
    }

    local regexp=$ROUNDUP_TEST_REGEXP
    local tests=$(grep "$regexp()" $ROUNDUP_FILE \
                    | sed "s/\($regexp\).*$/\1/")

    bash -n $ROUNDUP_FILE
    source $ROUNDUP_FILE

    echo "$yel${desc//$'\n'/ }$clr"

    for ROUNDUP_TEST in $tests
    do
        if test "${utils/ $ROUNDUP_TEST /}" != "$utils"
        then continue
        fi

        set +e
        _given= GIVEN=
        THIS="$ROUNDUP_TMP/$ROUNDUP_TEST"
        GIVEN="$ROUNDUP_TMP/$ROUNDUP_TEST.given"
        mkdir -p "$THIS"
        trace=$( cd "$THIS" && (set -xe; $ROUNDUP_TEST) 2>&1)
        local result=$?
        set -e
        # disable test function
        eval "unset -f $ROUNDUP_TEST"
        eval "function __given_$ROUNDUP_TEST() { return $result; }"
        roundup_test_result $result "$trace"
    done
}

roundup_test_result() {
    local result=$1 trace="$2" color= mark= label=
    if test $result -eq 0
    then
        ((++passed))
        color=$grn mark=$check
    else
        ((++failed))
        color=$red mark=$cross
    fi
    label=${ROUNDUP_TEST//_/ }
    echo "$color $mark $clr$label $clr"
    if test $result -ne 0
    then
        echo "$trace" | roundup_trace
    fi
}

roundup_summarize() {
    let total=passed+failed || true
    local count=$(echo "$passed   $failed   $total" | wc -c)
    local line=$(yes = | head -n $count)
    local pcolor=$grn fcolor=$red
    test $passed -eq 0 && pcolor=$red
    test $failed -eq 0 && fcolor=$grn
    echo " $fcolor${line//$'\n'/}$clr"
    echo " $pcolor$passed$check  $fcolor$failed$cross  $total$sigma$clr "
    echo " $fcolor${line//$'\n'/}$clr"
    test $failed -eq 0 || echo $ROUNDUP_TMP
}

roundup_trace() {
    # delete first line
    sed '1d'    |
    # delete last line ("set +x")
    sed '$d'    |
    # trim leftmost + sign
    sed 's/^+//'   |
    # indent
    sed 's/^/    /' |
    # format return code
    sed '$s/++ rc=/=> /' |
    # highlight failing line
    # the sed magic puts every line into the hold buffer first, then
    # substitutes in the previous hold buffer content, prints that and starts
    # with the next cycle. at the end the last line (in the hold buffer)
    # is printed without substitution.
    sed -n "x;1!{ \$s/\(.*\)/$mag\1$clr/; };1!p;\$x;\$p"
}


roundup_repeat() {
    local events=modify,close_write,move_self
    local highlight=$'\033[36m'
    local normal=$'\033[m'
    local delay=0.1
    local delta=Δ
    local self=$(readlink -f $0)

    $self "$@" || true

    # by default, ^\ (QUIT) repeats, ^C (INT) quits
    # swap these to match signal names
    # I rather like the default as ^\ is easier to type
    #trap 'true' INT
    #trap 'exit 1' QUIT

    # TODO: pass watched file args separate from test file args ??
    local file=$(inotifywait -q -e $events --format %w *.sh)
    local time=$(date +%H:%M:%S)

    echo
    echo "$highlight$time $delta ${file:-"(restart)"} $normal"
    echo
    sleep $delay
    exec "$self" --repeat "$@"
}


if test "$0" = "${BASH_SOURCE[0]}"
then
    case "$1" in
        -r|--repeat)
            shift
            roundup_repeat "$@"
            ;;
    esac
    roundup_run "$@"
    failed=$?
    FF=255
    test $failed -gt $FF && failed=$FF || true
    exit $failed
fi


