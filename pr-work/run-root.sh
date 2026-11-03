#!/bin/bash
#
# Build a revision of inotify-tools as root in the container and run a command.
#
# Usage: run-root.sh REV|WORKTREE [command...]
#
# REV is a git revision. WORKTREE uses the current files, committed or not.
# The default command runs make check.
#
# The container runs as root with CAP_SYS_ADMIN, which fanotify needs. It
# builds in a tmpfs, because fanotify can't watch the container's overlayfs.
# The sources arrive as a tar stream, and the container has no writable host
# mount, so root can't create files on the host.

set -eu

PR_WORK=$(dirname "$(realpath "$0")")
ROOT=$(dirname "$PR_WORK")
IMAGE=inotify-tools-rust-timeout

if [[ $# -lt 1 ]]; then
    echo "usage: $0 REV|WORKTREE [command...]" >&2
    exit 2
fi
REV=$1
shift
if [[ $# -eq 0 ]]; then
    set -- make check
fi

docker build -q -t "$IMAGE" "$PR_WORK" > /dev/null

if [[ "$REV" == WORKTREE ]]; then
    tar -C "$ROOT" --exclude=.git --exclude=pr-work --exclude=target -cf - .
else
    git -C "$ROOT" archive "$REV"
fi | docker run --rm -i --cap-add SYS_ADMIN --tmpfs /build:exec \
    -e TMPDIR=/build -v "$PR_WORK:/pr-work:ro" "$IMAGE" \
    bash -c 'cd /build && tar -xf - && make >/build.log 2>&1 \
        || { cat /build.log; exit 3; }; "$@"' bash "$@"
