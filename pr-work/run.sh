#!/bin/bash
#
# Build a revision of inotify-tools in the container and run a command there.
#
# Usage: run.sh REV|WORKTREE [command...]
#
# REV is a git revision. WORKTREE uses the current files, committed or not.
# The default command runs the reproduction against the built binary.
# The container sees the sources through a tar stream, so it can't write to
# the worktree. The pr-work directory is mounted read-only at /pr-work.

set -eu

PR_WORK=$(dirname "$(realpath "$0")")
ROOT=$(dirname "$PR_WORK")
IMAGE=inotify-tools-cpp-timeout

if [[ $# -lt 1 ]]; then
    echo "usage: $0 REV|WORKTREE [command...]" >&2
    exit 2
fi
REV=$1
shift
if [[ $# -eq 0 ]]; then
    set -- /pr-work/repro.sh src/inotifywait
fi

docker build -q -t "$IMAGE" "$PR_WORK" > /dev/null

if [[ "$REV" == WORKTREE ]]; then
    tar -C "$ROOT" --exclude=.git --exclude=pr-work -cf - .
else
    git -C "$ROOT" archive "$REV"
fi | docker run --rm -i --user "$(id -u):$(id -g)" \
    -v "$PR_WORK:/pr-work:ro" "$IMAGE" /pr-work/container-run.sh "$@"
