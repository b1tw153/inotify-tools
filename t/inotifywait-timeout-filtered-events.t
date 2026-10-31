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

# Millisecond clock. Tests need GNU date %N and the timeout command.
case $(date +%s%N 2>/dev/null) in
'' | *[!0-9]*) ;;
*) command -v timeout >/dev/null 2>&1 && test_set_prereq TIMING ;;
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

# Filtered events, then matching events from about 1 second on.
gen_then_match() {
    n=0
    while [ ! -e stop ]; do
        touch watched/noise
        if [ $n -ge 5 ]; then
            touch watched/match
        fi
        n=$((n + 1))
        sleep 0.2
    done
}

# Filtered events, with one matching event after about 1 second.
gen_one_match() {
    n=0
    while [ ! -e stop ]; do
        touch watched/noise
        if [ $n -eq 5 ]; then
            touch watched/match
        fi
        n=$((n + 1))
        sleep 0.2
    done
}

# A new directory every second.
gen_dirs() {
    n=0
    while [ ! -e stop ]; do
        mkdir watched/d$n
        n=$((n + 1))
        sleep 1
    done
}

# Run a command under a guard. Sets rc and elapsed_ms.
# Arguments: timeout period in seconds, then the command.
run_timed() {
    period=$1
    shift
    export LD_LIBRARY_PATH="../../libinotifytools/src/"
    t0=$(now_ms)
    timeout $((period + 4)) "$@" >out 2>err
    rc=$?
    t1=$(now_ms)
    elapsed_ms=$((t1 - t0))
    echo "# rc=$rc elapsed_ms=$elapsed_ms"
}

# Check for status 2, no earlier than the period and no later than the period
# plus the tolerance.
check_exit2_on_time() {
    period=$1
    test "$rc" -eq 2 || { echo "# expected exit 2, got $rc"; return 1; }
    test "$elapsed_ms" -ge $((period * 1000)) ||
        { echo "# exited early"; return 1; }
    test "$elapsed_ms" -le $((period * 1000 + late_ms)) ||
        { echo "# exited late"; return 1; }
}

# Run one watch against a generator and require exit 2 on time.
# Arguments: generator, period, then the tool options before the path.
case_exit2() {
    gen=$1
    period=$2
    shift 2
    rm -rf watched stop
    mkdir watched
    noise_start "$gen"
    run_timed "$period" ../../src/$backend --quiet --timeout "$period" "$@" watched
    noise_stop
    check_exit2_on_time "$period"
}

run_suite() {
    label=$1
    shift
    backend="$*"
    period=2

    test_expect_success TIMING "$label: include filter, spaced events, exit 2 on time" '
        test_when_finished noise_stop &&
        case_exit2 gen_spaced $period --include match
    '

    test_expect_success TIMING "$label: exclude filter, spaced events, exit 2 on time" '
        test_when_finished noise_stop &&
        case_exit2 gen_spaced $period --exclude noise
    '

    if [ "$label" = inotify ]; then
        test_expect_success TIMING "$label: includei filter, spaced events, exit 2 on time" '
            test_when_finished noise_stop &&
            case_exit2 gen_spaced $period --includei MATCH
        '

        test_expect_success TIMING "$label: excludei filter, spaced events, exit 2 on time" '
            test_when_finished noise_stop &&
            case_exit2 gen_spaced $period --excludei NOISE
        '
    fi

    test_expect_success TIMING "$label: continuous filtered events, exit 2 on time" '
        test_when_finished noise_stop &&
        case_exit2 gen_continuous $period --include match
    '

    test_expect_success TIMING "$label: matching event after filtered events, exit 0" '
        test_when_finished noise_stop &&
        rm -rf watched stop &&
        mkdir watched &&
        noise_start gen_then_match &&
        run_timed $period ../../src/$backend --timeout $period --include match watched &&
        noise_stop &&
        test "$rc" -eq 0 &&
        test "$elapsed_ms" -lt $((period * 1000)) &&
        grep match out
    '

    test_expect_success TIMING "$label: monitor mode, filtered events only, exit 2 on time" '
        test_when_finished noise_stop &&
        case_exit2 gen_spaced $period --monitor --include match
    '

    test_expect_success TIMING "$label: monitor mode, matching event restarts the timeout" '
        test_when_finished noise_stop &&
        rm -rf watched stop &&
        mkdir watched &&
        noise_start gen_one_match &&
        run_timed $period ../../src/$backend --quiet --monitor --timeout $period --include match watched &&
        noise_stop &&
        test "$rc" -eq 2 &&
        test "$elapsed_ms" -ge $(((period + 1) * 1000)) &&
        test "$elapsed_ms" -le $(((period + 1) * 1000 + late_ms))
    '

    test_expect_success TIMING "$label: monitor, recursive, include, new directories, exit 2 on time" '
        test_when_finished noise_stop &&
        case_exit2 gen_dirs $period --monitor --recursive --include match
    '

    test_expect_success TIMING "$label: timeout 0 waits indefinitely despite filtered events" '
        test_when_finished noise_stop &&
        rm -rf watched stop &&
        mkdir watched &&
        noise_start gen_spaced &&
        export LD_LIBRARY_PATH="../../libinotifytools/src/" &&
        timeout 3 ../../src/$backend --quiet --timeout 0 --include match watched >out 2>err
        rc=$?
        noise_stop &&
        test "$rc" -eq 124
    '
}

run_suite inotify inotifywait

if fanotify_supported; then
    run_suite fanotify fsnotifywait --fanotify
fi

test_done
