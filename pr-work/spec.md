# Spec: `--timeout` isn't restarted by filtered events

This spec is the contract for the fix and the regression test of
[inotify-tools#243](https://github.com/inotify-tools/inotify-tools/issues/243).
It applies to the C++ code on the `cpp` branch and to the Rust code on the
`master` branch. The section "Branch notes" lists where the two differ.

## Documented behavior

The `inotifywait` man page describes the option this way:

> `-t <seconds>, --timeout <seconds>`: Exit if an appropriate event has not
> occurred within `<seconds>` seconds. If `<seconds>` is zero (the default),
> wait indefinitely for an event.

The man page describes exit status 2 this way:

> The -t option was used and an event did not occur in the specified interval of
> time.

Exit status 0 means that an event being listened for occurred. The
`fsnotifywait` man page is a link to the `inotifywait` page, so the same
contract covers `fsnotifywait`.

The man page describes the filters this way. The `--include` option says
"Process events only for the subset of files whose filenames match". The
`--exclude` option says "Do not process any events for the subset of files whose
filenames match".

## Definitions

- **Filter:** One of the options `--include`, `--includei`, `--exclude` or
  `--excludei`.
- **Appropriate event:** An event that the program reports to the user. It has a
  type the user requested, and it passes the filter. A `--quiet` option
  suppresses output but doesn't change which events are appropriate. This is the
  man page's term.
- **Filtered event:** Any other event that occurs on a watched path. These cases
  are all filtered events:
  - An event that the filter rejects.
  - In `--recursive` mode with `--include`, a directory event that the program
    doesn't report because of the filter.
  - An unrequested event. This is an event of a type the user didn't request,
    which the program uses only internally. With `--monitor` and `--recursive`,
    the program adds `create`, `moved_to` and `moved_from` to its watch mask, so
    that it can watch new directories. It reports these events only when the
    user requested their type with `-e`, or gave no `-e` option.
- **Timeout period:** The `<seconds>` value given to `--timeout`.

## Required behavior

These requirements apply to `inotifywait`. They also apply to
`fsnotifywait --fanotify` where the system supports fanotify. Each requirement
that names a filter applies to all four filters.

### All modes

- **R1. Filtered events don't restart the timeout.** Without `--monitor`, the
  program exits with status 2 one timeout period after it starts watching,
  unless an appropriate event occurs first. Filtered events have no effect on
  when it exits. This holds at any rate of filtered events:
  - Events spaced apart, at intervals shorter than the timeout period.
  - A continuous stream with no pause between events.
- **R2. An appropriate event still ends the wait.** An appropriate event that
  occurs before the timeout expires makes the program exit with status 0, even
  if filtered events arrive before it. The program reports the event as usual.
- **R3. Monitor mode restarts the timeout on appropriate events only.** With
  `--monitor`, the timeout period starts when watching starts. It starts again
  after each appropriate event. The program exits with status 2 when one timeout
  period passes without an appropriate event. Filtered events have no effect on
  when it exits.
- **R4. Monitor mode keeps running while appropriate events arrive.** With
  `--monitor`, the program keeps running while appropriate events arrive at
  intervals shorter than the timeout period. Filtered events between them don't
  shorten the period.
- **R5. A quiet program still restarts the timeout.** With `--monitor`, an
  appropriate event starts a new timeout period even when `--quiet` given twice
  stops the program from printing it.
- **R6. The timeout doesn't fire early.** The program doesn't exit with status 2
  before a full timeout period has passed. Filtered events don't shorten the
  period.
- **R7. A zero timeout still means no timeout.** With `--timeout 0`, or without
  the option, the program waits indefinitely, with or without filtered events.
- **R8. The timer uses a monotonic clock.** Changes to the system time have no
  effect on when the timeout expires.

### Recursive monitor mode

These requirements cover `--monitor --recursive`, where the program also
receives events that it uses only internally.

- **R9. Unrequested events don't restart the timeout.** With `-m -r -e modify`
  and files created in the watched tree, the program exits with status 2 one
  timeout period after it starts watching. This holds at any rate of unrequested
  events.
- **R10. The program still acts on unrequested events.** A directory created in
  the watched tree during the timeout period gets a watch. An appropriate event
  in that directory is reported and starts a new timeout period.
- **R11. Later unrequested events don't extend a restarted period.** After an
  appropriate event restarts the timeout period, unrequested events don't extend
  it.
- **R12. A requested type is appropriate even when the program also uses it.**
  With `-m -r -e create`, each created file is an appropriate event and starts a
  new timeout period.
- **R13. New directories that the filter rejects don't restart the timeout.**
  With `-m -r --include` and a new directory that the filter rejects every
  second, the program exits with status 2 one timeout period after it starts
  watching.

## Unchanged behavior

- With no filter and no events, the program still exits with status 2 one
  timeout period after it starts watching.
- Errors from the wait or the read still exit with status 1.
- Which paths a filter accepts doesn't change.
- `inotifywatch --timeout` keeps its current behavior. That program uses
  `alarm()` for its timeout and calls the library with a blocking timeout.

## Timing tolerance

Tests accept an exit up to 2 seconds after the timeout expires, to allow for
process startup and a loaded machine. An exit more than a few seconds late
counts as a failure. The tolerance must stay shorter than the time the old
behavior takes, so that the old behavior still fails.

A test that checks for an early exit starts its clock no later than the moment
the program starts watching.

The library functions take a whole number of seconds. When the program carries
one timeout period across several library calls, it may round the time left up
to a whole second. The tolerance above still applies.

A test that exercises the bug needs a guard, such as the `timeout` command, so
that it fails rather than hangs on an unfixed build.

## Library API

The public C functions are in `inotifytools/inotifytools.h`:

```c
struct inotify_event* inotifytools_next_event(long int timeout);
struct inotify_event* inotifytools_next_events(long int timeout, int num_events);
```

A note in their documentation reads:

> If the function `inotifytools_ignore_events_by_regex()` has been called with a
> non-NULL parameter, this function will not return on events which match the
> regular expression passed to that function. However, the `timeout` period
> begins again each time a matching event occurs.

The same documentation describes `timeout` as the "maximum amount of time, in
seconds, to wait for an event." The note and that description disagree. This
spec resolves the disagreement in favor of the maximum.

- **L1. A call returns once its timeout expires.** A call returns NULL once
  `timeout` seconds have passed since the call began, unless an event that
  passes the filter is available first. Filtered events don't restart the
  period. After a timeout, `inotifytools_error()` returns 0.
- **L2. Each call starts a new timeout period.** Each call gets its full
  `timeout`.
- **L3. The documented `timeout` values keep their meaning.**
  - A negative `timeout` blocks until an event that passes the filter occurs, or
    an error occurs.
  - For `inotifytools_next_event()`, a `timeout` of zero blocks like a negative
    value.
  - For `inotifytools_next_events()`, a `timeout` of zero doesn't block.
- **L4. A zero timeout still finds a queued event.** A zero-timeout call to
  `inotifytools_next_events()` returns a queued event that passes the filter,
  even when filtered events are queued ahead of it. A second zero-timeout call
  returns the next such event. When only filtered events are queued, the call
  returns NULL promptly.
- **L5. A call doesn't lose or reorder events.** When a call times out, a later
  call returns any event that the library has already read from the kernel and
  that passes the filter.
- **L6. The ABI doesn't change.** No symbol or signature changes.
- **L7. The timer uses a monotonic clock.** Changes to the system time have no
  effect on when a call times out.

## Library documentation

- **D1.** The documentation of `inotifytools_next_event()` and
  `inotifytools_next_events()` states L1 and L2. Both branches use the same
  sentences. The `@note` replaces the sentence that begins "However, the @a
  timeout period begins again" with this text:

  > Those events do not restart the @a timeout period. The function returns NULL
  > once @a timeout seconds have passed since the call began, unless an event
  > that passes the filter is available first. Each call to this function starts
  > a new @a timeout period.

  The `@param timeout` text adds this sentence for a positive value:

  > If @a timeout is positive, the function will return NULL if no event occurs
  > within @a timeout seconds.

  The `@return` text adds this sentence:

  > After a timeout, inotifytools_error() is 0.

- **D2.** The `@param timeout` text for a zero timeout describes what the code
  does. It differs between the branches only where the code differs. See "Branch
  notes".
- **D3.** Code comments call the events that the filter rejects "filtered
  events". This matches the spec, the test and the PR.

## Regression test

- **T1.** The test follows the repository's conventions. It is a sharness test
  (a shell test harness) at `t/inotifywait-timeout-filtered-events.t`. It runs
  with the existing test runner and under `make check`.
- **T2.** The test has a bounded run time, even against a build with the bug.
- **T3.** The test fails against a build with the bug and passes against a fixed
  build. The R9 and R11 cases fail against a build that fixes only the library.
- **T4.** The test runs each applicable case again with
  `fsnotifywait --fanotify` when the system supports fanotify, as the existing
  tests do.
- **T5.** The run time stays short, because the suite runs in CI on every
  commit.

The test covers these cases at a minimum:

| Case | Setup | Expected | Covers |
| :- | :- | :- | :- |
| Include filter | `--include`, filtered events every 0.5 s | Exit 2 on time | R1 |
| Exclude filter | `--exclude`, filtered events every 0.5 s | Exit 2 on time | R1 |
| Includei filter | `--includei`, filtered events every 0.5 s | Exit 2 on time | R1 |
| Excludei filter | `--excludei`, filtered events every 0.5 s | Exit 2 on time | R1 |
| Continuous events | Filtered events with no pause | Exit 2 on time | R1 |
| Appropriate event | Filtered events, then an appropriate event before the timeout | Exit 0, event reported | R2 |
| Monitor mode | `--monitor`, filtered events only | Exit 2 on time | R3 |
| Monitor restart | `--monitor`, one appropriate event among filtered events | Exit 2 one period after it | R3 |
| Monitor stream | `--monitor`, appropriate events more often than the period | Still running after more than one period | R4 |
| No filter | No filter and no events | Exit 2 on time | Unchanged |
| Zero timeout | `--timeout 0`, filtered events | Still running | R7 |
| No timeout | No `--timeout`, filtered events | Still running | R7 |
| Unrequested events | `-m -r -e modify`, files created | Exit 2 on time | R9 |
| New directory | `-m -r -e modify`, a new directory, then an appropriate event in it | Event reported, exit 2 one period after it | R10, R11 |
| Requested create | `-m -r -e create`, files created | Still running after more than one period | R12 |
| Quiet restart | `-m -r -qq`, one appropriate event | Exit 2 one period after it | R5 |
| Hidden directory events | `-m -r --include`, a new directory every second | Exit 2 on time | R13 |
| Recursive zero timeout | `-m -r --timeout 0`, files created | Still running | R7 |

The C API test in `libinotifytools/src/test.cpp` covers L1, L3 and L4 with these
cases:

| Case | Expected |
| :- | :- |
| `next_events(0)`, a filtered event queued ahead of a passing event | Returns the passing event |
| Two `next_events(0)` calls, a filtered event queued between two passing events | Returns each passing event in turn |
| `next_events(0)`, only filtered events queued | NULL in under 0.5 s |
| `next_events(0)`, nothing queued | NULL in under 0.5 s |
| `next_events(1)`, only filtered events queued | NULL after 1 s to 3 s |
| `next_event(1)`, only filtered events queued | NULL after 1 s to 3 s |

## Out of scope

- Without `--monitor`, `inotifywait --recursive --include` exits with status 0
  and prints nothing when a directory that the filter rejects is created. This
  behavior is a separate issue from the timeout. It affects only `master`.
- Sub-second `--timeout` values.

## Branch notes

| Item | `cpp` | `master` |
| :- | :- | :- |
| Library code | `libinotifytools/src/inotifytools.cpp` | `libinotifytools/src/inotify.rs` |
| Library documentation | Doxygen blocks in `inotifytools.cpp` | Doxygen blocks in `inotifytools/inotifytools.h` |
| Program main loop | `src/inotifywait.cpp` | `src/inotifywait.rs` |
| One period across calls | The program passes the whole seconds left, rounded up | The library's Rust wait function takes a deadline |
| R13 directory events | The library filters them, so the library fix covers R13 | They pass the library filter since commit 3e09f13, so the program fix covers R13 |
| Monotonic clock | `clock_gettime(CLOCK_MONOTONIC)`, which needs `-lrt` before glibc 2.17 | `std::time::Instant` |

The zero-timeout read loops differ. Both meet L4. From reading the code, which
no test has checked, they differ under a continuous stream of filtered events:

- **`cpp`:** After each filtered event, the code calls `select()` with a zero
  timeout again. It keeps reading while events are queued.
- **`master`:** The code reads the kernel queue once. If that read holds only
  filtered events, the call returns NULL.

## Measured behavior before the fix

These runs used the `pr-work/Dockerfile` container. Each run had an 8-second
guard from GNU `timeout`, which exits with status 124. The `cpp` builds are the
bookworm package 3.22.6.0-4 and a build of 440ad5f. They gave the same results
to within 10 ms.

| Case | `cpp` | `master` at e763f49 |
| :- | :- | :- |
| `-m -t 2 --include`, appropriate events every 0.5 s for 3 s | Exit 2 at 4.5 s | Not measured |
| `-m -t 2 --include`, filtered events every 0.5 s for 7 s | Killed at 8.0 s | Not measured |
| `--exclude -t 2`, continuous filtered events | Killed at 8.0 s | Killed at 8.0 s |
| `-m -r -t 2 -e modify`, a file created every 0.5 s | Killed at 8.0 s | Killed at 8.0 s |
| `-m -r -t 2 --include`, a new directory every second | Killed at 8.0 s | Not measured |
| `-m -r -t 3 --include '\.txt$'`, a new directory every second | Not measured | Killed at 8.0 s |

The `pr-work/repro.sh` script covers the same bug without `--monitor`.
