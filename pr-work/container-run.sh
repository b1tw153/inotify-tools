#!/bin/bash
#
# Run inside the container. Read a source tar from stdin and build it in a
# private directory, then run the commands in "$@" from the build directory.
# The commands see the built binary at src/inotifywait.

set -eu

BUILD_DIR=$(mktemp -d)
cd "$BUILD_DIR"
tar -xf -

{
    ./autogen.sh
    ./configure --enable-static --disable-shared
    make -j"$(nproc)"
} > "$BUILD_DIR.log" 2>&1 || {
    cat "$BUILD_DIR.log"
    exit 3
}

"$@"
