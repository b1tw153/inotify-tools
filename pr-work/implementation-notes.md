# Implementation notes for the `--timeout` fix

These notes are for the `implementer`. Don't give them to `test-writer`. The
contract is in `spec.md`.

## Measurements

These results come from a build of `master` at e763f49, run in the
`pr-work/Dockerfile` container. The guard kills the process at 8 seconds and
gives exit status 124.

| Command under test | Events | Result |
| :- | :- | :- |
| `-m --include -t 2`, matching | One matching event per second | Exit 124, restarts as intended |
| `-m -r --include '\.txt$' -t 3` | One new directory per second | Exit 124, the bug |
| `-r --include '\.txt$' -t 3` | One new directory after 1 second | Exit 0 at 1 second, out of scope |
| `--exclude -t 2` | Continuous excluded events | Exit 124, the bug |
| `--include -t 4` | Noise, then a match at 1 second | Exit 0 at 1 second |

## Where the bug lives

- `Inotifytools::next_events_raw()` in `libinotifytools/src/inotify.rs` loops
  back with `continue` after a filtered event. Each pass builds a new `timespec`
  from the full `timeout` for `ppoll()`. Two other `continue` paths skip events
  in the same way: the tool's own `open_by_handle_at()` events, and mount or
  filesystem events with no resolvable path. They need the same treatment.
- The main loop in `src/inotifywait.rs` calls `lib.next_event(o.timeout)` once
  per event. In monitor mode it starts a new full period after every returned
  event, including events it doesn't report. Recursive directory events pass the
  library's filter on purpose, and the tool's internal move events also come
  back this way.

## Traps

- A deadline clamped at zero doesn't fix a continuous stream. `ppoll()` with a
  zero timeout still reports a non-empty queue as ready, so the loop keeps
  reading and filtering. Measured case 4 must exit 2. The loop has to give up
  once the deadline has passed and the events on hand are all filtered.
- The zero timeout of `inotifytools_next_events()` is a non-blocking check. It
  must still read and return an event that is already queued.
- `inotifytools_next_event()` and `Inotifytools::next_event()` map zero to
  blocking, and negative values block. Keep that mapping.
- The minimum Rust version is 1.63. `std::time::Instant` is monotonic and is
  available there. Pass sub-second remainders to `ppoll()` through `tv_nsec`.
- `inotifywatch` only passes `BLOCKING_TIMEOUT` and uses `alarm()` for its own
  timeout. It shouldn't need changes.

## Suggested shape

Hold a deadline rather than a duration. Give the library's Rust wait function a
deadline parameter, so that `inotifywait` can keep one deadline across calls and
reset it only after an appropriate event. The C entry points compute a deadline
from `timeout` at call entry.

Update the two header notes in
`libinotifytools/src/inotifytools/inotifytools.h`, as `spec.md` describes.
