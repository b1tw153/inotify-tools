#!/bin/sh

test_description='--timeout is not restarted by filtered events

Regression test for inotify-tools issue 243. Filtered events must not restart
the --timeout period. An appropriate event ends the wait with status 0. In
monitor mode, only appropriate events restart the period.
'

. ./fanotify-common.sh
. ./sharness.sh

# Tolerance: an exit up to 2 seconds after the timeout expires is accepted.
late_ms=2000

export LD_LIBRARY_PATH="../../libinotifytools/src/"

# Millisecond clock. Tests need GNU date %N, the timeout command and a sleep
# that accepts fractions.
case $(date +%s%N 2>/dev/null) in
'' | *[!0-9]*) ;;
*)
    command -v timeout >/dev/null 2>&1 &&
        sleep 0.01 >/dev/null 2>&1 &&
        test_set_prereq TIMING
    ;;
esac

now_ms() {
    ns=$(date +%s%N)
    echo $((ns / 1000000))
}

noise_pid=

# Start a background event generator. Arguments are the generator command.
noise_start() {
    rm -f stop
    ( "$@" ) >/dev/null 2>&1 &
    noise_pid=$!
}

# Stop the generator. Safe to call more than once.
noise_stop() {
    touch stop
    if test -n "$noise_pid"; then
        wait "$noise_pid" 2>/dev/null
        noise_pid=
    fi
    # The generator output is discarded, so it reports problems in diag.
    if test -f diag; then
        cat diag
        rm -f diag
    fi
}

# Wait until the program under test reports that it is watching, for at most
# 5 seconds. The program must run without --quiet, because it reports on
# standard error to the file err.
await_watch() {
    tries=0
    until grep -q 'Watches established' err 2>/dev/null; do
        tries=$((tries + 1))
        if [ "$tries" -ge 50 ]; then
            echo "# watch not established" >>diag
            return 0
        fi
        sleep 0.1
    done
}

# Generators. Each loops until the stop file appears.

# Filtered events on a file every 0.5 seconds.
gen_spaced() {
    while [ ! -e stop ]; do
        touch watched/noise
        sleep 0.5
    done
}

# Filtered events with no pause.
gen_continuous() {
    while [ ! -e stop ]; do
        echo x >watched/noise
    done
}

# No events at all.
gen_none() {
    :
}

# Filtered events, with matching events about 1 second after the program
# starts watching. The time of the first matching event goes to the file evt.
# Argument: "repeat" keeps matching from then on. "once" matches one time.
gen_match() {
    mode=$1
    await_watch
    step=0
    while [ ! -e stop ]; do
        touch watched/noise
        if [ "$step" -eq 5 ]; then
            now_ms >evt
        fi
        if [ "$step" -eq 5 ] || { [ "$mode" = repeat ] && [ "$step" -gt 5 ]; }; then
            touch watched/match
        fi
        step=$((step + 1))
        sleep 0.2
    done
}

# One matching event every second, with a filtered event in between.
gen_stream() {
    await_watch
    while [ ! -e stop ]; do
        touch watched/noise
        sleep 0.5
        touch watched/match
        sleep 0.5
    done
}

# A new directory every second.
gen_dirs() {
    step=0
    while [ ! -e stop ]; do
        mkdir watched/d$step
        step=$((step + 1))
        sleep 1
    done
}

# A new empty file every half second. A new file makes a create event and no
# modify event.
gen_creates() {
    step=0
    while [ ! -e stop ]; do
        : >watched/file$step
        step=$((step + 1))
        sleep 0.5
    done
}

# A new empty file every half second. About 0.5 seconds after the program
# starts watching, make a new directory. About 1 second after, write a file in
# it, and record the time in the file evt.
gen_newdir() {
    await_watch
    step=0
    while [ ! -e stop ]; do
        : >watched/file$step
        case $step in
        1) mkdir watched/sub ;;
        2)
            now_ms >evt
            echo x >watched/sub/file
            ;;
        esac
        step=$((step + 1))
        sleep 0.5
    done
}

# One modify event 1 second after the generator starts. The program runs with
# -qq and reports nothing, so this generator can't wait for it. The time of
# the event goes to the file evt.
gen_blind_modify() {
    sleep 1
    now_ms >evt
    echo x >>watched/target
}

# Run a command under a guard. Sets exit_status, end_ms and elapsed_ms.
# Arguments: guard in seconds, then the command.
run_guarded() {
    guard_s=$1
    shift
    start_ms=$(now_ms)
    timeout "$guard_s" "$@" >out 2>err
    exit_status=$?
    end_ms=$(now_ms)
    elapsed_ms=$((end_ms - start_ms))
    echo "# exit_status=$exit_status elapsed_ms=$elapsed_ms"
}

# Run a command under a guard of 4 seconds more than the timeout period.
# Arguments: timeout period in seconds, then the command.
run_timed() {
    period_s=$1
    shift
    run_guarded $((period_s + 4)) "$@"
}

# Check for status 2, no earlier than the period and no later than the period
# plus the tolerance.
check_exit2_on_time() {
    period_s=$1
    test "$exit_status" -eq 2 || { echo "# expected exit 2, got $exit_status"; return 1; }
    test "$elapsed_ms" -ge $((period_s * 1000)) ||
        { echo "# exited early"; return 1; }
    test "$elapsed_ms" -le $((period_s * 1000 + late_ms)) ||
        { echo "# exited late"; return 1; }
}

# Check for status 2, no earlier than the period after the event whose time is
# in the file evt, and no later than that plus the tolerance.
check_exit2_after_event() {
    period_s=$1
    test "$exit_status" -eq 2 || { echo "# expected exit 2, got $exit_status"; return 1; }
    test -s evt || { echo "# no event was made"; return 1; }
    since_ms=$((end_ms - $(cat evt)))
    echo "# since_event_ms=$since_ms"
    test "$since_ms" -ge $((period_s * 1000)) ||
        { echo "# exited early"; return 1; }
    test "$since_ms" -le $((period_s * 1000 + late_ms)) ||
        { echo "# exited late"; return 1; }
}

# Create a fresh watched directory and start a generator.
# Arguments: the generator command, then its arguments.
setup_watch() {
    rm -rf watched stop evt out err diag &&
        mkdir watched &&
        noise_start "$@"
}

# Run one watch against a generator and require exit 2 on time.
# Arguments: generator, period, then the tool options before the path.
case_exit2() {
    gen=$1
    period_s=$2
    shift 2
    setup_watch "$gen"
    # $backend is unquoted on purpose, see run_suite.
    run_timed "$period_s" ../../src/$backend --quiet --timeout "$period_s" "$@" watched
    noise_stop
    check_exit2_on_time "$period_s"
}

# Run one watch against a generator and require that it is still running when
# the guard ends it. The guard exits with status 124.
# Arguments: generator, guard in seconds, then the tool options before the
# path.
case_running() {
    gen=$1
    guard_s=$2
    shift 2
    setup_watch "$gen"
    run_guarded "$guard_s" ../../src/$backend "$@" watched
    noise_stop
    test "$exit_status" -eq 124
}

# Run one watch against a generator that makes a matching event, and require
# exit 2 one period after that event. The program runs without --quiet, so
# that the generator can wait for it.
# Arguments: generator, its argument, period, then the tool options before the
# path.
case_restart() {
    gen=$1
    genarg=$2
    period_s=$3
    shift 3
    setup_watch "$gen" $genarg
    run_timed "$period_s" ../../src/$backend --timeout "$period_s" "$@" watched
    noise_stop
    check_exit2_after_event "$period_s"
}

# Arguments: a label, whether the backend supports --recursive (yes or no),
# then the program and its fixed options.
run_suite() {
    label=$1
    rec=$2
    shift 2
    # $backend is left unquoted on purpose, so "fsnotifywait --fanotify"
    # splits into a command and an option.
    backend="$*"
    # Timeout of the cases that only wait for the exit.
    period=1
    # Timeout of the cases that restart the period. It leaves room to see
    # whether an event restarted it.
    rperiod=2

    test_expect_success TIMING "$label: include filter, spaced events, exit 2 on time" '
        test_when_finished noise_stop &&
        case_exit2 gen_spaced $period --include match
    '

    test_expect_success TIMING "$label: exclude filter, spaced events, exit 2 on time" '
        test_when_finished noise_stop &&
        case_exit2 gen_spaced $period --exclude noise
    '

    test_expect_success TIMING "$label: includei filter, spaced events, exit 2 on time" '
        test_when_finished noise_stop &&
        case_exit2 gen_spaced $period --includei MATCH
    '

    test_expect_success TIMING "$label: excludei filter, spaced events, exit 2 on time" '
        test_when_finished noise_stop &&
        case_exit2 gen_spaced $period --excludei NOISE
    '

    test_expect_success TIMING "$label: continuous filtered events, exit 2 on time" '
        test_when_finished noise_stop &&
        case_exit2 gen_continuous $period --include match
    '

    test_expect_success TIMING "$label: matching event after filtered events, exit 0" '
        test_when_finished noise_stop &&
        setup_watch gen_match repeat &&
        run_timed $rperiod ../../src/$backend --timeout $rperiod --include match watched &&
        noise_stop &&
        test "$exit_status" -eq 0 &&
        test "$elapsed_ms" -lt $((rperiod * 1000)) &&
        grep match out
    '

    test_expect_success TIMING "$label: monitor mode, filtered events only, exit 2 on time" '
        test_when_finished noise_stop &&
        case_exit2 gen_spaced $period --monitor --include match
    '

    test_expect_success TIMING "$label: monitor mode, matching event restarts the timeout" '
        test_when_finished noise_stop &&
        case_restart gen_match once $rperiod --monitor --include match
    '

    test_expect_success TIMING "$label: monitor mode, matching events more often than the period keep it running" '
        test_when_finished noise_stop &&
        case_running gen_stream $((rperiod + 1)) --timeout $rperiod --monitor --include match
    '

    test_expect_success TIMING "$label: no filter and no events, exit 2 on time" '
        test_when_finished noise_stop &&
        case_exit2 gen_none $period
    '

    test_expect_success TIMING "$label: timeout 0 waits indefinitely despite filtered events" '
        test_when_finished noise_stop &&
        case_running gen_spaced $((period + 2)) --timeout 0 --include match
    '

    test_expect_success TIMING "$label: no timeout option waits indefinitely despite filtered events" '
        test_when_finished noise_stop &&
        case_running gen_spaced $((period + 2)) --include match
    '

    if [ "$rec" = yes ]; then
        test_expect_success TIMING "$label: monitor, recursive, include, new directories, exit 2 on time" '
            test_when_finished noise_stop &&
            case_exit2 gen_dirs $rperiod --monitor --recursive --include match
        '

        test_expect_success TIMING "$label: monitor, recursive, unrequested events, exit 2 on time" '
            test_when_finished noise_stop &&
            case_exit2 gen_creates $period --monitor --recursive -e modify
        '

        test_expect_success TIMING "$label: monitor, recursive, new directory then event in it, restarts the timeout" '
            test_when_finished noise_stop &&
            case_restart gen_newdir "" $rperiod --monitor --recursive -e modify &&
            grep " file$" out
        '

        test_expect_success TIMING "$label: monitor, recursive, requested create events keep it running" '
            test_when_finished noise_stop &&
            case_running gen_creates $((rperiod + 1)) --timeout $rperiod --monitor --recursive -e create
        '

        test_expect_success TIMING "$label: monitor, recursive, -qq, appropriate event restarts the timeout" '
            test_when_finished noise_stop &&
            setup_watch gen_blind_modify &&
            run_timed $rperiod ../../src/$backend -qq --timeout $rperiod --monitor --recursive -e modify watched &&
            noise_stop &&
            check_exit2_after_event $rperiod
        '

        test_expect_success TIMING "$label: monitor, recursive, timeout 0 waits indefinitely despite unrequested events" '
            test_when_finished noise_stop &&
            case_running gen_creates $((period + 2)) --timeout 0 --monitor --recursive
        '
    fi
}

run_suite inotify yes inotifywait

if fanotify_supported; then
    if fanotify_supported -m -r; then
        fan_rec=yes
    else
        fan_rec=no
    fi
    run_suite fanotify "$fan_rec" fsnotifywait --fanotify
fi

test_done
