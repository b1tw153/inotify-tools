# Spec: filtered and unrequested events must not extend `--timeout`

This spec is the contract for the fix and its regression test. It covers
[inotify-tools#243](https://github.com/inotify-tools/inotify-tools/issues/243).

## Terms

- **Filter:** One of the `inotifywait` options `--include`, `--includei`,
  `--exclude` or `--excludei`.
- **Filtered event:** An event on a watched path that the filter rejects. The
  program doesn't print it or act on it.
- **Delivered event:** An event that the filter accepts, or any event when no
  filter is set.
- **Unrequested event:** A delivered event whose type the user didn't request.
  With `--monitor` and `--recursive`, `inotifywait` adds `create`, `moved_to`
  and `moved_from` to its watch mask so that it can watch new directories. It
  doesn't print these events unless the user requested their type with `-e`, or
  requested all events by giving no `-e`.
- **Appropriate event:** A delivered event that isn't an unrequested event. This
  is the man page's term. `inotifywait` prints appropriate events, unless
  `--quiet` is given twice.
- **Timeout period:** The `<seconds>` value of `-t` or `--timeout`.

## Documented behavior

The `inotifywait` man page describes `-t <seconds>, --timeout <seconds>`:

> Exit if an appropriate event has not occurred within \<seconds> seconds. If
> \<seconds> is zero (the default), wait indefinitely for an event.

The man page describes exit status 2:

> The -t option was used and an event did not occur in the specified interval of
> time.

The man page describes the filters this way. `--include` says "Process events
only for the subset of files whose filenames match". `--exclude` says "Do not
process any events for the subset of files whose filenames match".

A filtered event isn't an appropriate event. An unrequested event isn't one
either.

## Requirements

### Program behavior

These requirements apply to `inotifywait`. They also apply to `fsnotifywait`
with `--fanotify`, where the system supports fanotify.

- **R1.** A filtered event doesn't extend the timeout period. With a filter and
  no delivered event, the program exits with status 2 one timeout period after
  it starts waiting. This holds however many filtered events arrive, and at
  whatever interval.
- **R2.** R1 holds for all four filters.
- **R3.** R1 holds when filtered events arrive continuously with no pause
  between them. A process that renames files in a tight loop produces this load.
- **R4.** A delivered event that arrives within the timeout period ends the wait
  as before. Without `--monitor`, the program prints the event and exits with
  status 0. Filtered events that arrive before it don't change this.
- **R5.** With `--monitor`, each delivered event starts a new timeout period.
  The program exits with status 2 one timeout period after the last delivered
  event. Filtered events don't extend that period.
- **R6.** With `--monitor`, the program keeps running while delivered events
  arrive at intervals shorter than the timeout period. Filtered events in
  between don't shorten the period.
- **R7.** With no filter and no events, the program exits with status 2 one
  timeout period after it starts waiting.
- **R8.** With a timeout of zero or no `--timeout` option, the program waits
  indefinitely. Filtered events don't end the wait.

### Unrequested events with `--monitor --recursive`

These requirements apply to `inotifywait`. They also apply to `fsnotifywait`
with `--fanotify`, where the system supports fanotify and `--recursive`.

- **R19.** An unrequested event doesn't extend the timeout period. With
  `-m -r -e modify` and files created in the watched tree, the program exits
  with status 2 one timeout period after it starts waiting. This holds however
  many unrequested events arrive, and at whatever interval.
- **R20.** The program still acts on unrequested events. A directory created in
  the watched tree during the timeout period gets a watch. An appropriate event
  in that directory is printed and starts a new timeout period.
- **R21.** With `-m -r`, each appropriate event starts a new timeout period, as
  in R5. Unrequested events after it don't extend that period.
- **R22.** An event of a requested type is appropriate even when the program
  also needs it to follow new directories. For example, with `-m -r -e create`
  each created file starts a new timeout period.
- **R23.** An appropriate event starts a new timeout period even when `--quiet`
  given twice stops the program from printing it.
- **R24.** With `-m -r --include` and new directories that the filter rejects,
  the program exits with status 2 one timeout period after it starts waiting.
  The library treats these events as filtered events, so R1 already requires
  this. The regression test covers it as a separate case.
- **R25.** With a timeout of zero or no `--timeout` option, `-m -r` waits
  indefinitely. Unrequested events don't end the wait.
- **R26.** The library functions keep their whole-second `timeout` parameter.
  The program may round the time left in the period up to a whole second. The
  tolerance below still applies.

### Timing tolerance

"One timeout period" allows these tolerances, so that a test can be reliable on
a loaded machine.

- The program must not exit more than 100 ms before the period ends.
- The program should exit within 1 second after the period ends. A regression
  test may allow more on a slow machine. It must allow less than the shortest
  time that the old behavior would take, so that the old behavior still fails.

### Library behavior

The public functions are in `inotifytools/inotifytools.h`:

```c
struct inotify_event* inotifytools_next_event(long int timeout);
struct inotify_event* inotifytools_next_events(long int timeout, int num_events);
int inotifytools_ignore_events_by_regex(char const* pattern, int flags);
int inotifytools_ignore_events_by_inverted_regex(char const* pattern, int flags);
```

- **R9.** A call returns `NULL` with `inotifytools_error()` equal to 0 when
  `timeout` seconds pass with no delivered event. Filtered events don't restart
  that time.
- **R10.** A later call starts a new `timeout` period. Each call gets its full
  `timeout`.
- **R11.** These documented `timeout` values keep their meaning:
  - A negative `timeout` blocks until a delivered event or an error.
  - For `inotifytools_next_events()`, a `timeout` of zero doesn't block.
  - For `inotifytools_next_event()`, a `timeout` of zero blocks like a negative
    value.
- **R12.** A call doesn't lose or reorder events. A delivered event that the
  program has already read from the kernel is returned by a later call, even
  when the current call times out first.
- **R13.** The API and ABI of the library don't change.
- **R14.** The time measurement doesn't depend on the system clock. Setting the
  system clock doesn't shorten or extend the timeout.

### Documentation

- **R15.** The notes on `inotifytools_next_event()` and
  `inotifytools_next_events()` state the behavior in R9 and R10. They replace
  the sentence that says the timeout period begins again each time a matching
  event occurs.

### Regression test

- **R16.** The test follows the repository's sharness convention. It is a `.t`
  file in the `t/` directory and runs with the existing test runner.
- **R17.** The test has a bounded run time, even against a build with the bug.
- **R18.** The test fails against a build with the bug and passes against a
  fixed build.
- **R27.** The test covers R19 to R25. The R19 and R24 cases fail against a
  build that has only the library fix, and pass against a build that also has
  the program fix.

## Out of scope

- **Filter semantics.** Which paths a filter accepts doesn't change.
- **The `inotifywatch` program.** It uses `alarm()` for its timeout, and it
  calls the library with a blocking timeout.
- **The `master` branch.** A separate task checks it.

## Measured behavior before the fix

These runs used the bookworm package 3.22.6.0-4 and a build of 440ad5f, in the
`pr-work/Dockerfile` container. Both builds gave the same results to within 10
ms. Each run had an 8-second limit from GNU `timeout`.

| Case | Exit | Time |
| :- | :- | :- |
| `-m -t 2 --include`, delivered events every 0.5 s for 3 s | 2 | 4.5 s |
| `-m -t 2 --include`, filtered events every 0.5 s for 7 s | killed | 8.0 s |
| `-m -r -t 2 -e modify`, created files every 0.5 s for 7 s | killed | 8.0 s |
| `-m -r -t 2 --include`, a new directory every second | killed | 8.0 s |

The library fix alone ends the `--include` case after 2 s. It doesn't change
the `-e modify` case, which R19 covers.

The `pr-work/repro.sh` script covers the same bug without `--monitor`.
