# Build and test environment for the --timeout reproduction.
#
# It holds bookworm's own inotify-tools package at /usr/bin/inotifywait, and
# the tools that build master. Bookworm's Rust 1.63 is the project's minimum
# supported version.
#
#   docker build -t inotify-tools-rust-timeout pr-work
#   docker run --rm --user "$(id -u):$(id -g)" -v "$PWD:/src" -w /src \
#       inotify-tools-rust-timeout make
FROM debian:bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates cargo g++ gcc git inotify-tools libc6-dev make procps \
        rustc shellcheck \
    && rm -rf /var/lib/apt/lists/*

ENV CARGO_HOME=/tmp/cargo HOME=/tmp
