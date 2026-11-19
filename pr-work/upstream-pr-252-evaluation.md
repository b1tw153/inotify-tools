# Upstream PR #252 and this branch

[PR #252](https://github.com/inotify-tools/inotify-tools/pull/252) by `omrzk`
fixes issue #243 on `master`. This note compares it with this branch's fix for
the `cpp` branch. Facts come from `gh` and `git` on 2026-11-18.

## Recommendation

Don't retire the `cpp` work. PR #252 fixes the Rust rewrite only. The `cpp`
branch still has the bug, and Debian bookworm and Ubuntu 24.04 ship the `cpp`
code. The decision belongs to the user.

## What upstream merged

All of these PRs target `master`. None targets `cpp`.

| PR | Merged | Change |
| :- | :- | :- |
| #252 | 2026-11-14 | Library keeps one monotonic deadline across filtered events. Rust tests and header notes. Closes #243. |
| #253 | 2026-11-15 | Batch wait with `num_events > 1` respects the timeout and stops spinning on `FIONREAD`. |
| #254 | 2026-11-15 | CLI test `t/inotifywait-filtered-timeout.t`. It covers `--exclude` with `--timeout 1`. |
| #255 | 2026-11-16 | C API partial-batch tests. Corrected header text for zero and negative timeouts. |
| #256 | 2026-11-17 | C API test that `inotifytools_next_event(0)` blocks. |
| #257 | 2026-11-18 | Rust and C API idle-wait tests. |

## Status of `cpp`

- The upstream `cpp` head is still `440ad5f`, the base of this branch. No PR
  targets `cpp`.
- The bug reproduces on `440ad5f` and on bookworm's 3.22.6.0-4 package. See the
  table in `pr-draft.md`.
- Issue #243 is closed as completed. A `cpp` PR can't say "Fixes #243". It can
  refer to #243 and #252 instead.

## Gaps on `master` after the upstream PRs

These come from reading the code. I didn't run `master`.

- **`-m -r` unrequested events.** `src/inotifywait.rs` on `master` is the same
  as at the base of the Rust worker branch. The main loop still calls
  `next_event(o.timeout)` after every returned event. So with `-m -r`, the
  `create`, `moved_to` and `moved_from` events that `inotifywait` adds still
  restart the timeout. The Rust worker branch fixes this in
  `src/inotifywait.rs`. Upstream merged no such change.
- **Test coverage.** The upstream CLI test covers `--exclude` only. This
  branch's test also covers `--include`, `--includei`, `--excludei`, monitor
  mode, `-m -r` and fanotify.

## Gap on `cpp` that this branch doesn't fix

PR #253 fixed a spin in the `num_events > 1` batch wait on `master`. The same
loop exists on `cpp` and on this branch, in
`inotifytools_next_events()` around the `ioctl(inotify_fd, FIONREAD, ...)`
call. It ignores the timeout. This comes from reading the code. I didn't run it.
`inotifywait` calls the library with one event at a time, so the CLI doesn't
reach this loop.

## Changes if the `cpp` PR goes ahead

- Replace "Fixes #243." with a reference to #243 and to #252 on `master`.
- Replace `RUST_PR_LINK` with #252. Say that #252 doesn't cover the `-m -r`
  case, and that this PR does.
- Align the header notes with the wording #252 and #255 merged on `master`. For
  example, "Ignored events do not restart a positive @a timeout while waiting
  for an event which passes the filter."
- Consider naming the CLI test after upstream's
  `t/inotifywait-filtered-timeout.t`.
- Decide whether to port the #253 batch-wait fix to `cpp` here or in a separate
  PR.

## Changes for the Rust worker branch

The Rust branch's library fix overlaps #252 and #253. It will conflict with
`master`. Only its `src/inotifywait.rs` change for `-m -r` and its extra test
cases add something new. A smaller follow-up PR on `master` could carry those.
