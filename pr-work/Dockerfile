# Build and test environment for the inotifywait --timeout fix.
# The inotify-tools package provides the reference binary, /usr/bin/inotifywait.
FROM debian:bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        autoconf \
        automake \
        bash \
        clang-format \
        g++ \
        gcc \
        inotify-tools \
        libtool \
        make \
    && rm -rf /var/lib/apt/lists/*
