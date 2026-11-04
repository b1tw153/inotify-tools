# Proposed PR draft

## Before opening the PR

- Delete the `pr-work/` directory from the branch.
- Consider squashing the branch into two commits, one for the test and one for
  the fix. The later commits fix a regression that a review found and address
  review notes.
- Review the C API change described under "Library API" in the body. It changes
  documented behavior of `inotifytools_next_event()` and
  `inotifytools_next_events()`. It also documents a limit of zero-timeout
  calls to `inotifytools_next_events()`.
- Decide whether these gaps in the new test matter. Each one is checked by
  reading the code only.
  - The test covers `--timeout 0` but not an omitted `--timeout`. Both set the
    same value, `BLOCKING_TIMEOUT`, in `src/inotifywait.rs`.
  - No test checks that the timer ignores changes to the system clock. The fix
    uses `std::time::Instant`, which is monotonic.
  - No test covers the exit status 1 error paths of the wait.
  - `inotifywatch --timeout` is unchanged. It uses `alarm()` and a blocking
    `next_event()`.
- The new test takes about 21 seconds for each backend. Shorten it with
  `period=1` or by dropping the `--includei` and `--excludei` cases if
  upstream asks.
- Consider filing `issue-recursive-include-exit0.md` as a separate issue.

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

A zero-timeout call to `inotifytools_next_events()` reads the kernel queue only
once. One read fills a 64 KiB buffer, which holds 4096 events without names
and fewer with names. If every event in that read is filtered, the call
returns NULL, and a later call returns the event queued behind them. Reading
again until the queue is empty could let a continuous stream of filtered events
keep the call from returning. The header documents this limit.

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

| Build | Reproduction |
| :- | :- |
| Debian bookworm `inotify-tools` package | Fails, guard kills it at 8 s |
| `master` at `e763f49` | Fails, guard kills it at 8 s |
| This branch | Exits 2 at 3 s, as expected |

The test suite ran as root with `CAP_SYS_ADMIN` in the same container, so the
fanotify cases ran too.

| Test | `master` at `e763f49` | This branch |
| :- | :- | :- |
| New test, inotify and fanotify | 16 of 20 cases fail | 20 of 20 pass |
| `fsnotifywait-errors.t` | Hangs | 7 of 7 pass |
| `fsnotifywait-subtree.t` | Case 3 fails | Case 3 fails |
| Other `t/*.t` tests | Pass | Pass |
| `libinotifytools` unit tests | Not run | 480122 of 480122 pass |

The new test ran on `master` with the test file copied in. The hang in
`fsnotifywait-errors.t` is the same bug. The case "mount option automatically
enables fanotify" runs `inotifywait --mount --timeout 1 .` with stderr in a file
on the watched mount. Each write to that file causes an event that
`inotifywait` doesn't report, and on `master` each one restarts the timeout. A
guard killed it after 8 seconds. On this branch it exits 2 after 1 second.

The `fsnotifywait-subtree.t` failure depends on the container. Filesystem
watches aren't supported there, so the filesystem and mount tests skip.
`cargo fmt --check` is clean.

### Out of scope

Without `--monitor`, `inotifywait --recursive --include` exits with status 0 and
prints nothing when a directory that doesn't match the filter is created. That
is a separate issue from the timeout.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
