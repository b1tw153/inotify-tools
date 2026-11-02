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
    # src/Makefile.am sets fsnotifywait_CPPFLAGS, which replaces the include path
    # in AM_CPPFLAGS. Pass the path here so that fsnotifywait compiles.
    ./configure --enable-static --disable-shared --enable-fanotify \
        CPPFLAGS="-I$BUILD_DIR/libinotifytools/src"
    make -j"$(nproc)"
} > "$BUILD_DIR.log" 2>&1 || {
    cat "$BUILD_DIR.log"
    exit 3
}

"$@"
