# Proposed PR draft

## Before opening the PR

- Delete the `pr-work/` directory from the branch.
- Consider squashing the branch into two commits, one for the test and one for
  the fix. The branch has five commits after `e763f49`. The later three fix a
  regression that the review found and address review notes.
- Review the C API change described under "Library API" in the body. It changes
  documented behavior of `inotifytools_next_event()` and
  `inotifytools_next_events()`.

## Title

Don't restart --timeout on filtered events

## Body

Fixes #243.

`inotifywait --timeout` should exit "if an appropriate event has not occurred
within `<seconds>` seconds". With `--include`, `--includei`, `--exclude` or
`--excludei`, each filtered event restarted the timeout at its full value. A
steady stream of non-matching events kept the timeout from ever firing.

The bug had two sources.

- `Inotifytools::next_events_raw()` looped after a filtered event and passed the
  full timeout to `ppoll()` again.
- In `--monitor` mode, `inotifywait` started a new period after every event the
  library returned. That included events it doesn't report, such as directory
  events hidden by `--recursive --include`.

### Changes

- The library wait now holds a deadline on a monotonic clock instead of a
  duration. A new `next_event_until()` takes the deadline. The existing
  functions compute it from `timeout` when the call starts.
- A call reads the kernel queue at least once before it checks the deadline. A
  zero timeout in `inotifytools_next_events()` still returns an event queued
  behind filtered events. A continuous stream of filtered events still ends the
  wait at the deadline.
- `inotifywait` keeps one deadline across calls. It resets the deadline only
  after an event it reports.

### Library API

The header notes for `inotifytools_next_event()` and
`inotifytools_next_events()` said that the timeout "begins again each time a
matching event occurs". The same header calls `timeout` the "maximum amount of
time, in seconds, to wait for an event". This PR follows the second statement.
Filtered events no longer restart the period. The notes now say so.

The `timeout` parameter docs also said "If timeout is non-negative, the function
is non-blocking." That was wrong for both functions. They now state the actual
behavior. A zero timeout blocks in `inotifytools_next_event()` and is a
non-blocking check in `inotifytools_next_events()`. Negative values block in
both.

No symbol or signature changes.

### Tests

- `t/inotifywait-timeout-filtered-events.t` covers all four filter options,
  spaced and continuous filtered events, a matching event, monitor mode, hidden
  directory events with `--recursive --include` and `--timeout 0`. It runs the
  same cases with `fsnotifywait --fanotify` where fanotify is available. Each
  case has a `timeout` guard, so it fails rather than hangs on an unfixed build.
- `libinotifytools/src/test.cpp` adds C API cases. They cover zero-timeout calls
  with events queued behind filtered ones and a one-second timeout with only
  filtered events queued.

The reproduction runs `inotifywait --timeout 3` with `--include` and then
`--exclude` while a filtered event arrives every 0.5 seconds. Results in a
`debian:bookworm-slim` container with Rust 1.63:

| Build | New sharness test | Reproduction |
| :- | :- | :- |
| Debian bookworm `inotify-tools` package | Not run | Fails, guard kills it at 8 s |
| `master` at `e763f49` | 8 of 10 cases fail | Fails, guard kills it at 8 s |
| This branch | 10 of 10 pass | Exits 2 at 3 s, as expected |

The rest of `make check` passes on this branch. `cargo fmt --check` is clean.
Two cases in `fsnotifywait-errors.t` fail in the unprivileged container on both
`master` and this branch, because they need fanotify mount watches. The fanotify
cases of the new test were skipped there for the same reason. They haven't run
yet.

### Out of scope

Without `--monitor`, `inotifywait --recursive --include` exits with status 0 and
prints nothing when a directory that doesn't match the filter is created. That
is a separate issue from the timeout.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
