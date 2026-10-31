#!/bin/sh

test_description='Filtered events do not extend the --timeout period (issue #243)'

. ./fanotify-common.sh
. ./sharness.sh

export LD_LIBRARY_PATH="../../libinotifytools/src/"

# Length of the timeout under test, in seconds.
timeout_secs=2
# Extra seconds a run may take beyond the earliest correct exit before it is
# killed. A build that lets filtered events extend the timeout never exits on
# its own, so the kill bounds the run time.
grace_secs=3

# Stop the background process that creates filtered events, if any.
stop_noise() {
    if [ -n "$NOISE_PID" ]; then
        kill "$NOISE_PID" 2>/dev/null
        wait "$NOISE_PID" 2>/dev/null
        NOISE_PID=
    fi
}

# Rename a file over the name "noise" in the given directory. Each rename makes
# one moved_to event. The mode "slow" pauses one second between renames. The
# mode "tight" renames without a pause.
start_noise() {
    (
        trap 'kill "$sleep_pid" 2>/dev/null; exit 0' TERM
        while :; do
            echo x >"$1/noise.tmp" && mv -f "$1/noise.tmp" "$1/noise"
            if [ "$2" = slow ]; then
                sleep 1 &
                sleep_pid=$!
                wait "$sleep_pid"
            fi
        done
    ) &
    NOISE_PID=$!
}

# Rename a file over the name "index" in the given directory.
deliver_event() {
    echo x >"$1/index.tmp" && mv -f "$1/index.tmp" "$1/index"
}

# Make one filtered event, then wait a second, then make one delivered event.
# Do that three times.
stream_events() {
    for i in 1 2 3; do
        echo x >"$1/noise.tmp" && mv -f "$1/noise.tmp" "$1/noise"
        sleep 1
        deliver_event "$1"
    done
}

# Run a command for at most $2 seconds. Write these files, named after $1:
# .out and .err hold the output, .rc the exit status, .secs the run time in
# whole seconds and .killed is 1 if the command had to be killed.
bounded() {
    b_name=$1
    b_limit=$2
    shift 2
    b_start=$(date +%s)
    (
        "$@" >"$b_name.out" 2>"$b_name.err" &
        b_pid=$!
        echo "$b_pid" >"$b_name.pid"
        b_rc=0
        wait "$b_pid" || b_rc=$?
        date +%s >"$b_name.end"
        echo "$b_rc" >"$b_name.rc.tmp"
        mv "$b_name.rc.tmp" "$b_name.rc"
    ) &
    b_wrapper=$!
    b_n=0
    while [ ! -f "$b_name.rc" ] && [ "$b_n" -lt "$b_limit" ]; do
        sleep 1
        b_n=$((b_n + 1))
    done
    b_killed=0
    if [ ! -f "$b_name.rc" ]; then
        b_killed=1
        kill "$(cat "$b_name.pid")" 2>/dev/null
    fi
    wait "$b_wrapper"
    echo "$b_killed" >"$b_name.killed"
    echo $(($(cat "$b_name.end") - b_start)) >"$b_name.secs"
}

# Run one scenario. Arguments: a name, the noise mode (none, slow or tight),
# the delivered events (none, once or stream), the kill limit in seconds, and
# the command. The command gets the watched directory as its last argument.
run_case() {
    c_name=$1
    c_noise=$2
    c_deliver=$3
    c_limit=$4
    shift 4
    c_dir="$c_name.dir"
    NOISE_PID=
    c_pid=
    trap stop_noise EXIT
    mkdir "$c_dir" || return 1
    if [ "$c_noise" != none ]; then
        start_noise "$c_dir" "$c_noise"
    fi
    case $c_deliver in
    once)
        (sleep 1; deliver_event "$c_dir") &
        c_pid=$!
        ;;
    stream)
        stream_events "$c_dir" &
        c_pid=$!
        ;;
    esac
    bounded "$c_name" "$c_limit" "$@" "$c_dir"
    if [ -n "$c_pid" ]; then
        wait "$c_pid"
    fi
    stop_noise
}

show_case() {
    echo "$1: rc=$(cat "$1.rc") secs=$(cat "$1.secs")" \
        "killed=$(cat "$1.killed")" >&2
}

# The program exited by itself with status 2, and not earlier than $2 seconds
# after the start. The run time has a resolution of one second, so $2 is one
# below the earliest correct exit time.
timed_out() {
    show_case "$1"
    [ "$(cat "$1.killed")" = 0 ] &&
        [ "$(cat "$1.rc")" = 2 ] &&
        [ "$(cat "$1.secs")" -ge "$2" ]
}

# The program was still running when the limit passed.
still_waiting() {
    show_case "$1"
    [ "$(cat "$1.killed")" = 1 ]
}

# Number of delivered events the program printed.
printed_events() {
    grep -c ' index$' "$1.out"
}

# Options shared by all runs. Events are limited to moved_to, so only the
# renames made by this test count.
common="-q -e moved_to"
iw=../../src/inotifywait
limit_idle=$((timeout_secs + grace_secs))
min_idle=$((timeout_secs - 1))

test_expect_success 'run the scenarios in parallel' '
    run_case include slow none $limit_idle \
        $iw $common --timeout $timeout_secs --include "index\$" &
    run_case includei slow none $limit_idle \
        $iw $common --timeout $timeout_secs --includei "INDEX\$" &
    run_case exclude slow none $limit_idle \
        $iw $common --timeout $timeout_secs --exclude "noise\$" &
    run_case excludei slow none $limit_idle \
        $iw $common --timeout $timeout_secs --excludei "NOISE\$" &
    run_case delivered slow once $limit_idle \
        $iw $common --timeout $timeout_secs --include "index\$" &
    run_case monitor_after_delivered slow once $((1 + limit_idle)) \
        $iw $common --monitor --timeout $timeout_secs --include "index\$" &
    run_case no_filter none none $limit_idle \
        $iw $common --timeout $timeout_secs &
    run_case zero_timeout slow none $limit_idle \
        $iw $common --timeout 0 --include "index\$" &
    run_case no_timeout slow none $limit_idle \
        $iw $common --include "index\$" &
    if fanotify_supported; then
        run_case fan_include slow none $limit_idle \
            ../../src/fsnotifywait --fanotify $common \
            --timeout $timeout_secs --include "index\$" &
        run_case fan_delivered slow once $limit_idle \
            ../../src/fsnotifywait --fanotify $common \
            --timeout $timeout_secs --include "index\$" &
        run_case fan_no_filter none none $limit_idle \
            ../../src/fsnotifywait --fanotify $common \
            --timeout $timeout_secs &
    fi
    wait
'

test_expect_success 'run the scenarios that need a quiet machine' '
    run_case tight tight none $limit_idle \
        $iw $common --timeout $timeout_secs --include "index\$" &
    run_case monitor_stream none stream $((3 + limit_idle)) \
        $iw $common --monitor --timeout $timeout_secs --include "index\$" &
    wait
'

test_expect_success '--include: filtered events do not extend the timeout' '
    timed_out include $min_idle
'

test_expect_success '--includei: filtered events do not extend the timeout' '
    timed_out includei $min_idle
'

test_expect_success '--exclude: filtered events do not extend the timeout' '
    timed_out exclude $min_idle
'

test_expect_success '--excludei: filtered events do not extend the timeout' '
    timed_out excludei $min_idle
'

test_expect_success 'Filtered events without pause do not extend the timeout' '
    timed_out tight $min_idle
'

test_expect_success 'A delivered event among filtered events exits with 0' '
    show_case delivered &&
    [ "$(cat delivered.killed)" = 0 ] &&
    [ "$(cat delivered.rc)" = 0 ] &&
    [ "$(printed_events delivered)" = 1 ]
'

test_expect_success '--monitor: timeout starts at the last delivered event' '
    timed_out monitor_after_delivered $((1 + min_idle)) &&
    [ "$(printed_events monitor_after_delivered)" = 1 ]
'

test_expect_success '--monitor: delivered events keep the program running' '
    timed_out monitor_stream $((3 + min_idle)) &&
    [ "$(printed_events monitor_stream)" = 3 ]
'

test_expect_success 'No filter and no events: timeout fires' '
    timed_out no_filter $min_idle
'

test_expect_success '--timeout 0 waits despite filtered events' '
    still_waiting zero_timeout
'

test_expect_success 'No --timeout waits despite filtered events' '
    still_waiting no_timeout
'

if fanotify_supported; then
    test_expect_success 'fanotify: filtered events do not extend the timeout' '
        timed_out fan_include $min_idle
    '

    test_expect_success 'fanotify: a delivered event among filtered events exits with 0' '
        show_case fan_delivered &&
        [ "$(cat fan_delivered.killed)" = 0 ] &&
        [ "$(cat fan_delivered.rc)" = 0 ] &&
        [ "$(printed_events fan_delivered)" = 1 ]
    '

    test_expect_success 'fanotify: no filter and no events: timeout fires' '
        timed_out fan_no_filter $min_idle
    '
fi

test_done
