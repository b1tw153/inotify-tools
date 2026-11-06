#!/bin/bash
#
# Check that inotifywait --timeout fires while filtered events keep arriving.
# Covers inotify-tools#243.
#
# Usage: repro.sh [path-to-inotifywait]
#
# Exit status: 0 if every case passes, 1 if a case fails, 2 if the control case
# or the setup goes wrong. Runs for at most about 40 seconds.

set -u

INOTIFYWAIT="${1:-inotifywait}"
TIMEOUT_SECS=3
GUARD_SECS=8
NOISE_INTERVAL=0.5
MATCH_DELAY_SECS=1
# Allow for process startup and a loaded machine.
MAX_ELAPSED_MS=$(( (TIMEOUT_SECS + 2) * 1000 ))

WORK_DIR="$(mktemp -d)" || exit 2
NOISE_PID=

stop_noise()
{
    if [[ -n "$NOISE_PID" ]]; then
        kill "$NOISE_PID" 2>/dev/null
        wait "$NOISE_PID" 2>/dev/null
        NOISE_PID=
    fi
}

# shellcheck disable=SC2317  # Invoked by the trap.
cleanup()
{
    stop_noise
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

# Rename a file over the name "noise" until killed. Each rename makes one
# moved_to event, which the filters under test reject.
generate_noise()
{
    local COUNT=0
    while true; do
        (( ++COUNT ))
        echo "$COUNT" > "$WORK_DIR/noise.tmp"
        mv "$WORK_DIR/noise.tmp" "$WORK_DIR/noise"
        sleep "$NOISE_INTERVAL"
    done
}

# Set by run_case. The guard kills inotifywait and reports exit status 124.
EXIT_STATUS=
ELAPSED_MS=

run_case()
{
    local START END
    START=$(date +%s%3N)
    timeout -k 1 "$GUARD_SECS" "$INOTIFYWAIT" -qq -e moved_to \
        --timeout "$TIMEOUT_SECS" "$@" "$WORK_DIR"
    EXIT_STATUS=$?
    END=$(date +%s%3N)
    ELAPSED_MS=$(( END - START ))
}

timed_out_in_time()
{
    [[ "$EXIT_STATUS" -eq 2 && "$ELAPSED_MS" -lt "$MAX_ELAPSED_MS" ]]
}

report()
{
    echo "$1: exit=$EXIT_STATUS elapsed=${ELAPSED_MS}ms (want exit=$2 under ${MAX_ELAPSED_MS}ms)"
}

"$INOTIFYWAIT" --help > /dev/null 2>&1
if [[ $? -eq 127 ]]; then
    echo "ERROR: cannot run $INOTIFYWAIT"
    exit 2
fi

# Control: without noise, the timeout must fire. A failure here says nothing
# about filtered events.
run_case --include '/index$'
report "control: --include, no noise" 2
if ! timed_out_in_time; then
    echo "ERROR: control case failed"
    exit 2
fi

generate_noise &
NOISE_PID=$!

RESULT=0

run_case --include '/index$'
report "--include, noise every ${NOISE_INTERVAL}s" 2
timed_out_in_time || RESULT=1

run_case --exclude '/noise(\.tmp)?$'
report "--exclude, noise every ${NOISE_INTERVAL}s" 2
timed_out_in_time || RESULT=1

# An appropriate event among the filtered events must still end the wait with
# exit status 0.
(
    sleep "$MATCH_DELAY_SECS"
    echo x > "$WORK_DIR/index.tmp"
    mv "$WORK_DIR/index.tmp" "$WORK_DIR/index"
) &
MATCH_PID=$!
run_case --include '/index$'
wait "$MATCH_PID"
report "--include, appropriate event after ${MATCH_DELAY_SECS}s" 0
[[ "$EXIT_STATUS" -eq 0 && "$ELAPSED_MS" -lt "$MAX_ELAPSED_MS" ]] || RESULT=1

stop_noise

if [[ "$RESULT" -eq 0 ]]; then
    echo "PASS: the timeout fired despite filtered events"
else
    echo "FAIL: a case failed, see above"
fi
exit "$RESULT"
