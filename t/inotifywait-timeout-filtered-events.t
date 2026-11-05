#!/bin/sh

test_description='Filtered and unrequested events do not extend the --timeout period (issue #243)'

. ./fanotify-common.sh
. ./sharness.sh

export LD_LIBRARY_PATH="../../libinotifytools/src/"

# Length of the timeout under test, in seconds.
timeout_secs=2
# Extra seconds a run may take beyond the earliest correct exit before it is
# killed. A build that lets filtered events extend the timeout never exits on
# its own, so the kill bounds the run time.
grace_secs=5
# Timeout of the stream scenario. It is longer than the one second between
# delivered events, so a loaded machine can be late by almost two seconds.
stream_timeout_secs=3
# Seconds before the appropriate event of the "late" scenarios. The timeout of
# these scenarios is $stream_timeout_secs. The late event is at least one
# whole second before the timeout would fire without it, so the run time shows
# whether the event restarted the timeout.
late_secs=2

# Stop the background processes that create events, if any.
stop_helpers() {
    for h_pid in "$NOISE_PID" "$DELIVER_PID"; do
        if [ -n "$h_pid" ]; then
            kill "$h_pid" 2>/dev/null
            wait "$h_pid" 2>/dev/null
        fi
    done
    NOISE_PID=
    DELIVER_PID=
}

# Stop the helpers and the program of the running case, then leave. Without
# this, a program with no timeout would outlive an interrupted test.
abort_case() {
    stop_helpers
    kill "$c_bounded" 2>/dev/null
    if [ -f "$c_name.pid" ]; then
        kill "$(cat "$c_name.pid")" 2>/dev/null
    fi
    exit 1
}

# Poll every 0.1 seconds, at most $1 times, until the command in the other
# arguments succeeds.
poll() {
    p_max=$1
    shift
    p_n=0
    until "$@"; do
        p_n=$((p_n + 1))
        if [ "$p_n" -ge "$p_max" ]; then
            return 1
        fi
        sleep 0.1
    done
}

# The program of case $1 has set up its watches, or has already exited. The
# program must run without -q, or it does not report the watches.
watching() {
    grep -q 'Watches established' "$1.err" 2>/dev/null || [ -f "$1.rc" ]
}

# Fail if any case reported a setup failure.
setup_ok() {
    for s_file in *.fail; do
        if [ -e "$s_file" ]; then
            echo "setup failed: $s_file" >&2
            return 1
        fi
    done
    return 0
}

# Make events in the given directory until stopped. The mode decides which.
# - slow: Rename a file over the name "noise", then pause one second. Each
#   rename makes one moved_to event.
# - tight: Rename a file over the name "noise" without a pause.
# - creates: Create a new empty file every half second. A new file makes a
#   create event and no modify event.
# - dirs: Create a new directory every second. A new directory makes a create
#   event.
start_noise() {
    (
        trap 'kill "$sleep_pid" 2>/dev/null; exit 0' TERM
        n=0
        while :; do
            n=$((n + 1))
            pause=
            case $2 in
            slow)
                echo x >"$1/noise.tmp" && mv -f "$1/noise.tmp" "$1/noise"
                pause=1
                ;;
            tight)
                echo x >"$1/noise.tmp" && mv -f "$1/noise.tmp" "$1/noise"
                ;;
            creates)
                : >"$1/file$n"
                pause=0.5
                ;;
            dirs)
                mkdir "$1/dir$n"
                pause=1
                ;;
            esac
            if [ -n "$pause" ]; then
                sleep "$pause" &
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

# Create a new empty file once a second, three times. Each file makes a create
# event.
stream_creates() {
    for i in 1 2 3; do
        sleep 1
        : >"$1/created$i"
    done
}

# Wait $2 seconds, then append to the file "target". The first append also
# creates the file, which makes a create event. Each append makes a modify
# event.
late_modify() {
    sleep "$2"
    echo x >>"$1/target"
}

# Wait one second, then create the directory "sub". Wait another second, then
# write a new file in it. The write makes a create and a modify event in "sub".
late_subdir() {
    sleep 1
    mkdir "$1/sub"
    sleep 1
    echo x >"$1/sub/file"
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
        echo "$b_pid" >"$b_name.pid.tmp"
        mv "$b_name.pid.tmp" "$b_name.pid"
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
        # The pid file may not exist yet. Wait for it, up to 5 seconds.
        if poll 50 test -f "$b_name.pid"; then
            kill "$(cat "$b_name.pid")" 2>/dev/null
        else
            kill "$b_wrapper" 2>/dev/null
        fi
    fi
    wait "$b_wrapper"
    echo "$b_killed" >"$b_name.killed"
    echo $(($(cat "$b_name.end") - b_start)) >"$b_name.secs"
}

# Run one scenario. Arguments: a name, the noise mode (none, slow, tight,
# creates or dirs), the delivered events (none, once, stream, creates, late,
# late_blind or subdir), the kill limit in seconds, and the command. The
# command gets the watched directory as its last argument.
run_case() {
    c_name=$1
    c_noise=$2
    c_deliver=$3
    c_limit=$4
    shift 4
    c_dir="$c_name.dir"
    NOISE_PID=
    DELIVER_PID=
    trap stop_helpers EXIT
    c_bounded=
    trap abort_case INT TERM
    if ! mkdir "$c_dir"; then
        echo "run_case $c_name: cannot create $c_dir" >&2
        : >"$c_name.fail"
        return 1
    fi
    if [ "$c_noise" != none ]; then
        start_noise "$c_dir" "$c_noise"
    fi
    bounded "$c_name" "$c_limit" "$@" "$c_dir" &
    c_bounded=$!
    # Start the delivered events only after the program has set up its watches.
    # The poll is bounded, so a broken build cannot hang the test.
    # The mode "late_blind" is for a program that runs with -qq and reports
    # nothing. It doesn't poll, and the pause before its event is the margin.
    if [ "$c_deliver" != none ]; then
        c_ready=watching
        if [ "$c_deliver" = late_blind ]; then
            c_ready=true
        fi
        if poll 100 $c_ready "$c_name"; then
            case $c_deliver in
            once)
                (sleep 1; deliver_event "$c_dir") &
                DELIVER_PID=$!
                ;;
            stream)
                stream_events "$c_dir" &
                DELIVER_PID=$!
                ;;
            creates)
                stream_creates "$c_dir" &
                DELIVER_PID=$!
                ;;
            late | late_blind)
                late_modify "$c_dir" "$late_secs" &
                DELIVER_PID=$!
                ;;
            subdir)
                late_subdir "$c_dir" &
                DELIVER_PID=$!
                ;;
            esac
        else
            echo "run_case $c_name: watches not established" >&2
            : >"$c_name.fail"
        fi
    fi
    wait "$c_bounded"
    if [ -n "$DELIVER_PID" ]; then
        wait "$DELIVER_PID"
    fi
    stop_helpers
    [ ! -e "$c_name.fail" ]
}

# Run a command in the background and remember its pid. A background shell
# ignores INT, so the main shell passes both INT and TERM on as TERM.
SPAWNED=
spawn() {
    "$@" &
    SPAWNED="$SPAWNED $!"
}
trap 'kill $SPAWNED 2>/dev/null; exit 1' INT TERM

show_case() {
    echo "$1: rc=$(cat "$1.rc") secs=$(cat "$1.secs")" \
        "killed=$(cat "$1.killed")" >&2
}

# The program exited by itself with status 2, and not earlier than $2 seconds
# after the start. The run time has a resolution of one second, so $2 is one
# below the earliest correct exit time. The test does not enforce the spec's
# tolerance of 100 ms for an early exit. The clock is too coarse. A program that
# exits less than one second early can pass. Only the filtered-event bug is
# caught, because it delays the exit by a whole timeout period or more.
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
# Options for runs that get delivered events. They omit -q, so that the program
# reports "Watches established." on standard error.
common_loud="-e moved_to"
iw=../../src/inotifywait
limit_idle=$((timeout_secs + grace_secs))
min_idle=$((timeout_secs - 1))
limit_stream=$((3 + stream_timeout_secs + grace_secs))
min_stream=$((3 + stream_timeout_secs - 1))
limit_late=$((late_secs + stream_timeout_secs + grace_secs))
min_late=$((late_secs + stream_timeout_secs - 1))
# Options of the runs with --monitor and --recursive. Only modify events are
# requested, so create events are unrequested. The loud variant omits -q, so
# that the program reports "Watches established." on standard error.
rec_quiet="-q -m -r -e modify"
rec_loud="-m -r -e modify"

test_expect_success 'run the scenarios in parallel' '
    spawn run_case include slow none $limit_idle \
        $iw $common --timeout $timeout_secs --include "index\$"
    spawn run_case includei slow none $limit_idle \
        $iw $common --timeout $timeout_secs --includei "INDEX\$"
    spawn run_case exclude slow none $limit_idle \
        $iw $common --timeout $timeout_secs --exclude "noise\$"
    spawn run_case excludei slow none $limit_idle \
        $iw $common --timeout $timeout_secs --excludei "NOISE\$"
    spawn run_case delivered slow once $limit_idle \
        $iw $common_loud --timeout $timeout_secs --include "index\$"
    spawn run_case monitor_after_delivered slow once $((1 + limit_idle)) \
        $iw $common_loud --monitor --timeout $timeout_secs \
        --include "index\$"
    spawn run_case no_filter none none $limit_idle \
        $iw $common --timeout $timeout_secs
    spawn run_case zero_timeout slow none $limit_idle \
        $iw $common --timeout 0 --include "index\$"
    spawn run_case no_timeout slow none $limit_idle \
        $iw $common --include "index\$"
    if fanotify_supported; then
        spawn run_case fan_include slow none $limit_idle \
            ../../src/fsnotifywait --fanotify $common \
            --timeout $timeout_secs --include "index\$"
        spawn run_case fan_delivered slow once $limit_idle \
            ../../src/fsnotifywait --fanotify $common_loud \
            --timeout $timeout_secs --include "index\$"
        spawn run_case fan_no_filter none none $limit_idle \
            ../../src/fsnotifywait --fanotify $common \
            --timeout $timeout_secs
    fi
    spawn run_case rec_modify creates none $limit_idle \
        $iw $rec_quiet --timeout $timeout_secs
    spawn run_case rec_include dirs none $limit_idle \
        $iw -q -m -r --timeout $timeout_secs --include "index\$"
    spawn run_case rec_zero creates none $limit_idle \
        $iw $rec_quiet --timeout 0
    spawn run_case rec_no_timeout creates none $limit_idle \
        $iw $rec_quiet
    if fanotify_supported -m -r; then
        spawn run_case fan_rec_modify creates none $limit_idle \
            ../../src/fsnotifywait --fanotify $rec_quiet \
            --timeout $timeout_secs
    fi
    wait &&
    setup_ok
'

test_expect_success 'run the scenarios that need a quiet machine' '
    spawn run_case rec_new_dir none subdir $limit_late \
        $iw $rec_loud --timeout $stream_timeout_secs
    spawn run_case rec_restart creates late $limit_late \
        $iw $rec_loud --timeout $stream_timeout_secs
    spawn run_case rec_create none creates $limit_stream \
        $iw -m -r -e create --timeout $stream_timeout_secs
    spawn run_case rec_qq none late_blind $limit_late \
        $iw -qq -m -r -e modify --timeout $stream_timeout_secs
    spawn run_case tight tight none $limit_idle \
        $iw $common --timeout $timeout_secs --include "index\$"
    spawn run_case monitor_stream none stream $limit_stream \
        $iw $common_loud --monitor --timeout $stream_timeout_secs \
        --include "index\$"
    wait &&
    setup_ok
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
    timed_out monitor_stream $min_stream &&
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

test_expect_success '-m -r -e modify: unrequested events do not extend the timeout (R19)' '
    timed_out rec_modify $min_idle &&
    [ ! -s rec_modify.out ]
'

test_expect_success '-m -r: an appropriate event in a new directory is printed and restarts the timeout (R20)' '
    timed_out rec_new_dir $min_late &&
    [ "$(grep -c " file$" rec_new_dir.out)" = 1 ]
'

test_expect_success '-m -r: an appropriate event restarts the timeout and later unrequested events do not extend it (R21)' '
    timed_out rec_restart $min_late &&
    [ "$(grep -c " target$" rec_restart.out)" = 1 ] &&
    ! grep -q CREATE rec_restart.out
'

test_expect_success '-m -r -e create: created files are appropriate and keep the program running (R22)' '
    timed_out rec_create $min_stream &&
    [ "$(grep -c " created[0-9]$" rec_create.out)" = 3 ]
'

test_expect_success '-m -r -qq: an appropriate event restarts the timeout (R23)' '
    timed_out rec_qq $min_late &&
    [ ! -s rec_qq.out ]
'

test_expect_success '-m -r --include: new directories rejected by the filter do not extend the timeout (R24)' '
    timed_out rec_include $min_idle
'

test_expect_success '-m -r --timeout 0 waits despite unrequested events (R25)' '
    still_waiting rec_zero
'

test_expect_success '-m -r without --timeout waits despite unrequested events (R25)' '
    still_waiting rec_no_timeout
'

if fanotify_supported -m -r; then
    test_expect_success 'fanotify: -m -r -e modify: unrequested events do not extend the timeout (R19)' '
        timed_out fan_rec_modify $min_idle
    '
fi

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
