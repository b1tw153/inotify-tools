# Spec: `--timeout` isn't restarted by filtered events

This spec is the contract for the fix and the regression test of
[inotify-tools#243](https://github.com/inotify-tools/inotify-tools/issues/243).

## Documented behavior

The `inotifywait` man page describes the option this way:

> `-t <seconds>, --timeout <seconds>`: Exit if an appropriate event has not
> occurred within `<seconds>` seconds. If `<seconds>` is zero (the default),
> wait indefinitely for an event.

Exit status 2 means that the timeout expired. Exit status 0 means that an event
being listened for occurred. The `fsnotifywait` man page is a link to the
`inotifywait` page, so the same contract covers `fsnotifywait`.

## Definitions

- **Appropriate event:** An event that `inotifywait` reports to the user. It has
  a type the user requested. It passes the `--include`, `--includei`,
  `--exclude` or `--excludei` filter. A `--quiet` option suppresses output but
  doesn't change which events are appropriate.
- **Filtered event:** Any other event that occurs on a watched path. These cases
  are all filtered events:
  - An event that the `--include` or `--exclude` filter rejects.
  - In `--recursive` mode with `--include`, a directory event that isn't
    reported because of the include filter.
  - An event of a type the user didn't request, which the tool only uses
    internally.
- **Timeout period:** The `<seconds>` value given to `--timeout`.

## Required behavior

1. **Filtered events don't restart the timeout.** Without `--monitor`, the tool
   exits with status 2 one timeout period after it starts watching, unless an
   appropriate event occurs first. Filtered events have no effect on when it
   exits. This holds at any rate of filtered events:
   - Events spaced apart, at intervals shorter than the timeout period.
   - A continuous stream with no pause between events.
2. **An appropriate event still ends the wait.** An appropriate event that
   occurs before the timeout expires makes the tool exit with status 0, even if
   filtered events arrive before it. The tool reports the event as usual.
3. **Monitor mode restarts the timeout on appropriate events only.** With
   `--monitor`, the timeout period starts when watching starts. It starts again
   after each appropriate event. The tool exits with status 2 when one timeout
   period passes without an appropriate event. Filtered events have no effect on
   when it exits.
4. **The timeout doesn't fire early.** The tool doesn't exit with status 2
   before a full timeout period has passed. Filtered events don't shorten the
   period.
5. **A zero timeout still means no timeout.** With `--timeout 0`, or without the
   option, the tool waits indefinitely, with or without filtered events.
6. **The timer uses a monotonic clock.** Changes to the system time have no
   effect on when the timeout expires.

Each of these behaviors applies to all four filter options. Each also applies to
`fsnotifywait --fanotify` where fanotify is available.

## Unchanged behavior

- A timeout with no events at all still exits with status 2.
- Errors from the wait or the read still exit with status 1.
- `inotifywatch --timeout` keeps its current behavior.

## Timing tolerance

Tests accept an exit up to 2 seconds after the timeout expires, to allow for
process startup and a loaded machine. An exit more than a few seconds late
counts as a failure. A test that exercises the bug needs a guard, such as the
`timeout` command, so that it fails rather than hangs on an unfixed build.

## Library API

The public C functions `inotifytools_next_event()` and
`inotifytools_next_events()` take a `timeout` in seconds. A note in their header
documentation currently reads:

> If the function `inotifytools_ignore_events_by_regex()` has been called with a
> non-NULL parameter, this function will not return on events which match the
> regular expression passed to that function. However, the `timeout` period
> begins again each time a matching event occurs.

The same header describes `timeout` as the "maximum amount of time, in seconds,
to wait for an event." The note and that description disagree. This spec
resolves the disagreement in favor of the maximum:

- Each call returns NULL once `timeout` seconds have passed since the call
  began, unless an event that passes the filter is available first. Filtered
  events don't restart the period.
- A negative `timeout` still blocks until an event occurs.
  `inotifytools_next_event()` still treats zero as blocking.
  `inotifytools_next_events()` still treats zero as a non-blocking check.
- The header note changes to state this behavior.
- The ABI doesn't change. No symbol or signature changes.

## Regression test

The test follows the repository's conventions. It is a sharness test (a shell
test harness) in the `t/` directory, named after the tool and the behavior. It
also runs under `make check`. The test covers these cases at a minimum:

| Case | Setup | Expected |
| :- | :- | :- |
| Include filter | `--include`, non-matching events every 0.5 seconds | Exit 2 on time |
| Exclude filter | `--exclude`, excluded events every 0.5 seconds | Exit 2 on time |
| Continuous events | Filtered events with no pause | Exit 2 on time |
| Matching event | Filtered events, then a matching event before the timeout | Exit 0 |
| Monitor mode | `--monitor`, filtered events only | Exit 2 on time |
| Hidden directory events | `--monitor --recursive --include`, a new directory every second | Exit 2 on time |

The test also runs the applicable cases with `fsnotifywait --fanotify` when the
system supports fanotify, as the existing tests do. Keep the run time short,
because the suite runs in CI on every commit.

## Out of scope

- Without `--monitor`, `inotifywait --recursive --include` exits with status 0
  and prints nothing when a directory that doesn't match the filter is created.
  This behavior is a separate issue from the timeout.
- Sub-second `--timeout` values.
