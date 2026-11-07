# Proposed PR draft

## Before opening the PR

- Open the PR against the `cpp` branch, not `master`.
- Delete the `pr-work/` directory from the branch.
- Consider squashing the branch into two commits, one for the test and one for
  the fix. The later commits extend the fix to `-m -r`, rewrite the test and
  address review notes.
- Replace `RUST_PR_LINK` in the body with the link to the matching PR on
  `master`.
- Review the C API change described under "Library API" in the body. It changes
  documented behavior of `inotifytools_next_event()` and
  `inotifytools_next_events()`.
- Decide whether these gaps in the new test matter. Each one is checked by
  reading the code only.
  - No test checks that the timer ignores changes to the system clock. The fix
    uses `CLOCK_MONOTONIC`.
  - No test checks that each library call starts a new period, that a negative
    timeout blocks, or that a timed-out call keeps its buffered events.
  - The `-qq` case can't wait for the watches to start, because the program
    prints nothing. Its first event comes 1 second after the program starts.
  - The new-directory case has about 0.5 seconds between steps. A loaded CI
    machine could break that margin.
- The new test takes about 42 seconds for inotify and about 84 seconds with
  fanotify. Shorten it by dropping the `--includei` and `--excludei` cases if
  upstream asks.

## Title

Don't restart --timeout on filtered events

## Body

Fixes #243.

`inotifywait --timeout` should exit "if an appropriate event has not occurred
within `<seconds>` seconds". With `--include`, `--includei`, `--exclude` or
`--excludei`, each filtered event restarted the timeout at its full value. A
steady stream of non-matching events kept the timeout from ever firing.

The bug had two sources.

- `inotifytools_next_events()` jumped back with `longjmp()` after a filtered
  event and passed the full timeout to `select()` again. `inotifywait` and
  `fsnotifywait` share this code.
- In `--monitor` mode, `inotifywait` started a new period after every event the
  library returned. With `-m -r`, that included the `create`, `moved_to` and
  `moved_from` events it adds to follow new directories, even when the user
  didn't request them. No filter is needed for this case.
  `inotifywait -m -r -t 2 -e modify` never timed out while files were created.

The Rust rewrite on `master` has the same bug. RUST_PR_LINK fixes it there in
the same way.

### Changes

- `inotifytools_next_events()` computes one deadline on `CLOCK_MONOTONIC` when
  the call starts. After a filtered event, it checks the deadline and passes
  only the time left to `select()`. Changes to the system clock don't affect the
  deadline.
- A retry after a partly read event now jumps back with `longjmp()` instead of
  calling the function again. A recursive call would start a new deadline.
- When a call times out, events already read stay in the buffer. The next call
  returns them.
- `inotifywait` keeps one deadline across calls. It resets the deadline only
  after an appropriate event, one that matches the requested events. This holds
  when `--quiet` stops the event from being printed. The library takes whole
  seconds, so `inotifywait` rounds the time left up to the next second.
- The library and `inotifywait` now call `clock_gettime()`. On glibc 2.16 and
  older, that function is in librt and needs `-lrt`. glibc 2.17 moved it into
  libc in December 2012. This PR doesn't add a `configure` check for it.
  `AC_SEARCH_LIBS([clock_gettime], [rt])` in `configure.ac` would add `-lrt`
  only where libc lacks the function. I haven't tested an older glibc, or the
  FreeBSD and Alpine CI builds.

### Library API

The notes for `inotifytools_next_event()` and `inotifytools_next_events()` said
that the timeout period "begins again each time a matching event occurs". The
same docs call `timeout` the "maximum amount of time, in seconds, to wait for an
event". This PR follows the second statement. Filtered events no longer restart
the period. The notes now say so, and they say that each call starts a new
period. Library callers that relied on the old note will see their calls return
sooner.

The `timeout` parameter docs also said "If timeout is non-negative, the function
is non-blocking." That was wrong for `inotifytools_next_event()`, where a zero
timeout blocks. The docs now state the behavior of each function. A positive
timeout returns NULL if no event passes the filter within that many seconds. A
zero timeout blocks in `inotifytools_next_event()` and doesn't block in
`inotifytools_next_events()`. A negative timeout blocks in both. The `@return`
docs now say that `inotifytools_error()` is 0 after a timeout.

No symbol or signature changes.

### Tests

- `t/inotifywait-timeout-filtered-events.t` covers all four filter options,
  spaced and continuous filtered events, and an appropriate event among filtered
  ones. In monitor mode it covers filtered events only, a restarted period and a
  stream of appropriate events. It covers no filter, `--timeout 0` and no
  `--timeout` option. With `--monitor --recursive`, it covers new directories
  hidden by `--include`, unrequested events, an event in a new directory,
  requested `create` events, `-qq` and `--timeout 0`. It runs the same cases
  with `fsnotifywait --fanotify` where fanotify is available. Each case has a
  `timeout` guard, so it fails rather than hangs on an unfixed build.
- `libinotifytools/src/test.cpp` adds C API cases. They cover zero-timeout calls
  with events queued behind filtered ones and a one-second timeout with only
  filtered events queued. These cases pass before and after the fix on this
  branch. They guard the zero-timeout behavior and match the cases added on
  `master`.

The reproduction runs `inotifywait --timeout 3` with `--include` and then
`--exclude` while a filtered event arrives every 0.5 seconds. Results in a
`debian:bookworm-slim` container with bookworm's GCC:

| Build | Reproduction |
| :- | :- |
| Debian bookworm `inotify-tools` package 3.22.6.0-4 | Fails, guard kills it at 8 s |
| `cpp` at `440ad5f` | Fails, guard kills it at 8 s |
| This branch | Exits 2 at 3 s, as expected |

With `-m -r -t 2 -e modify` and a new file every 0.5 seconds, the bookworm
package and `440ad5f` were still running when a guard killed them at 8 seconds.
This branch exits 2 after 2 seconds.

The test suite ran as root with `CAP_SYS_ADMIN` in the same container, so the
fanotify cases ran too. The build was on a tmpfs, because fanotify can't watch
the container's overlayfs.

| Test | `cpp` at `440ad5f` | This branch |
| :- | :- | :- |
| New test, inotify and fanotify | 20 of 36 cases fail | 36 of 36 pass |
| `fsnotifywait-subtree.t` | Case 3 fails | Case 3 fails |
| Other `t/*.t` tests | Pass | Pass |
| `libinotifytools` unit tests | Pass | Pass |

The new tests ran on `440ad5f` with the test files copied in. The
`fsnotifywait-subtree.t` failure depends on the container. Its `--filesystem`
case needs a loop mount, which the container doesn't allow. As a normal user,
the whole suite passes on this branch. `clang-format` reports no changes in the
changed C++ files.

### Out of scope

`inotifywatch --timeout` is unchanged. It uses `alarm()` and a blocking
`inotifytools_next_event()` call.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
