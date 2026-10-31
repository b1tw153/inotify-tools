#!/bin/bash
#
# Reproduce inotify-tools#243 against any inotifywait binary.
#
# Usage: repro.sh /path/to/inotifywait
#
# Exit status: 0 if every case passes, 1 if any case fails, 2 on a usage error.
# Each case is limited to HARD_LIMIT seconds, so the script always terminates.

set -u

TIMEOUT=2           # The --timeout value under test, in seconds.
HARD_LIMIT=6        # Kill inotifywait after this many seconds.
MARGIN_US=1000000   # Allowed lateness of the timeout, in microseconds.
EARLY_US=100000     # Allowed earliness of the timeout, in microseconds.
NOISE_INTERVAL=0.5  # Time between filtered events, in seconds.

if [[ $# -ne 1 || ! -x "$1" ]]; then
    echo "usage: $0 /path/to/inotifywait" >&2
    exit 2
fi
BIN=$1

LC_ALL=C
export LC_ALL

WORK_DIR=$(mktemp -d)
NOISE_PID=
FAILURES=0

stop_noise()
{
    if [[ -n "$NOISE_PID" ]]; then
        kill "$NOISE_PID" 2>/dev/null
        wait "$NOISE_PID" 2>/dev/null
        NOISE_PID=
    fi
}

cleanup()
{
    stop_noise
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

# Rename a file over the name "noise" until killed. Each rename makes one
# moved_to event that the filter under test rejects.
start_noise()
{
    (
        while true; do
            echo x > "$WORK_DIR/noise.tmp"
            mv -f "$WORK_DIR/noise.tmp" "$WORK_DIR/noise"
            sleep "$NOISE_INTERVAL"
        done
    ) &
    NOISE_PID=$!
}

# Run inotifywait with the given filter arguments. Set RC and ELAPSED_US.
run_inotifywait()
{
    local start end
    start=${EPOCHREALTIME/./}
    RC=0
    timeout --kill-after=1 "$HARD_LIMIT" "$BIN" -q -e moved_to \
        --timeout "$TIMEOUT" "$@" "$WORK_DIR" > /dev/null 2>&1 || RC=$?
    end=${EPOCHREALTIME/./}
    ELAPSED_US=$(( end - start ))
}

report()
{
    local name=$1 result=$2
    printf '%s: %s (exit %d after %d ms)\n' \
        "$result" "$name" "$RC" "$(( ELAPSED_US / 1000 ))"
    if [[ "$result" == FAIL ]]; then
        (( ++FAILURES ))
    fi
}

# Pass if inotifywait exits 2 at the expected time.
expect_timeout()
{
    local name=$1 low high
    low=$(( TIMEOUT * 1000000 - EARLY_US ))
    high=$(( TIMEOUT * 1000000 + MARGIN_US ))
    if [[ "$RC" -eq 2 && "$ELAPSED_US" -ge "$low" && "$ELAPSED_US" -le "$high" ]]
    then
        report "$name" PASS
    else
        report "$name" FAIL
    fi
}

run_inotifywait --include 'index$'
expect_timeout "control: no filtered events, timeout fires"

start_noise
run_inotifywait --include 'index$'
stop_noise
expect_timeout "bug: --include with filtered events, timeout fires"

start_noise
run_inotifywait --exclude 'noise$'
stop_noise
expect_timeout "bug: --exclude with filtered events, timeout fires"

# A matching event during the timeout must still end the wait with exit 0.
start_noise
(
    sleep 1
    echo x > "$WORK_DIR/index.tmp"
    mv -f "$WORK_DIR/index.tmp" "$WORK_DIR/index"
) &
MATCH_PID=$!
run_inotifywait --include 'index$'
wait "$MATCH_PID"
stop_noise
if [[ "$RC" -eq 0 ]]; then
    report "control: matching event among filtered events, exit 0" PASS
else
    report "control: matching event among filtered events, exit 0" FAIL
fi

if [[ "$FAILURES" -ne 0 ]]; then
    echo "RESULT: FAIL ($FAILURES cases failed against $BIN)"
    exit 1
fi
echo "RESULT: PASS (all cases passed against $BIN)"
