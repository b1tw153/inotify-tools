# Proposed PR draft

Notes for the opener. These aren't part of the PR.

- **Base branch:** `cpp`
- **Before opening:** Remove the `pr-work/` directory. It holds the spec, the
  container, the reproduction and this draft.
- **Title:** Stop filtered events from extending `--timeout`

## PR description

Fixes #243.

### Problem

`inotifywait --timeout` documents that it exits "if an appropriate event has not
occurred within `<seconds>` seconds". With `--include`, `--exclude` or their
case-insensitive forms, a filtered event could restart the timeout at its full
value. Filtered events that keep arriving could stop the timeout from ever
firing.

`inotifytools_next_events()` retries after a filtered event by jumping back with
`longjmp()`. Each retry set the `select()` timeout to the full value again.
`inotifywait` and `fsnotifywait` share this code path.

### Fix

- `inotifytools_next_events()` computes one deadline when the call starts. Each
  retry checks the deadline and passes only the time left to `select()`.
- A retry after a partly read event now jumps back with `longjmp()` instead of
  calling the function again. A recursive call would start a new deadline.
- The deadline uses `CLOCK_MONOTONIC`, so changing the system clock doesn't
  affect it.
- Events that were already read stay in the buffer when a call times out. The
  next call returns them.
- The API and ABI don't change. A timeout of zero or below keeps its documented
  meaning. Each call still gets a full timeout, so a delivered event still
  starts a new period with `--monitor`.

The function notes used to say that the timeout period begins again on each
filtered event. That sentence described the bug, so the notes now state the new
behavior. Library callers that relied on the old sentence will see their calls
return sooner.

### Tests

The new `t/inotifywait-timeout-filtered-events.t` test covers these cases:

- All four filters
- Filtered events that arrive with no pause
- A delivered event among filtered events
- `--monitor` timing
- No filter and no events
- `--timeout 0` and no `--timeout`
- Three `fsnotifywait --fanotify` cases, which run only where fanotify is
  available

I ran the results below in a `debian:bookworm-slim` container with bookworm's
GCC. The test script takes about 14 seconds and has a bounded run time, even
against a build with the bug.

| Build | Reproduction script | New test |
| :- | :- | :- |
| Debian bookworm package 3.22.6.0-4 | 2 of 4 fail | Not run |
| `cpp` at 440ad5f | 2 of 4 fail | 6 of 13 fail |
| This branch | All 4 pass | All 13 pass |

The reproduction's failing cases use `--timeout 2` and a filtered event every
0.5 seconds. On the two unfixed builds, `inotifywait` was still running when the
script killed it at 6 seconds. On this branch, it exits with status 2 after
about 2 seconds.

The full test suite passes on this branch, 25 of 25.

### Limitations

- The fanotify cases didn't run. I ran the test as a non-root user in the
  container, and it skipped them.
- `clock_gettime()` needs `-lrt` on glibc older than 2.17. This change doesn't
  add it, because the bookworm build doesn't need it. I haven't tested an older
  glibc, or the FreeBSD and Alpine CI builds.
- `inotifywait -m -r` adds `create`, `moved_to` and `moved_from` to its watch
  mask so it can follow new directories. Those events still restart the timeout
  when the user didn't request them. No filter is involved, so I left this for a
  separate change. For example, `inotifywait -m -r -t 2 -e modify` doesn't time
  out while a file is created every 0.5 seconds.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
