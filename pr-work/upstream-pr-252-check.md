# Check of upstream PR #252 against this branch

[PR #252](https://github.com/inotify-tools/inotify-tools/pull/252) was merged
into upstream `master` on 2026-11-14. Follow-up PRs #253 to #257 were merged
after it. This note records how upstream `master` at 6ccd641 behaves against
this branch's reproduction and regression test.

## What upstream changed

- PR #252 keeps one wait budget across filtered events in
  `Inotifytools::next_events_raw()`. It changes only the library and its header.
- PR #253 bounds the `num_events > 1` batch wait by the same deadline.
- PR #254 adds `t/inotifywait-filtered-timeout.t`. It covers `--exclude` with a
  timeout, without `--monitor` or `--recursive`.
- PRs #255 to #257 add C API tests for batch and zero timeouts.
- `src/inotifywait.rs` is unchanged since e763f49. Its main loop still calls
  `lib.next_event(o.timeout)` with the full timeout on every pass.

## Measurements

Upstream 6ccd641 was built in the `pr-work/Dockerfile` image and run as root
with `CAP_SYS_ADMIN`.

| Check | Bookworm package | Upstream 6ccd641 |
| :- | :- | :- |
| `pr-work/repro.sh` | Fails, exit 124 at the 8 s guard | Passes, exit 2 at 3 s |
| Upstream `inotifywait-filtered-timeout.t` | Not run | 2 of 2 pass |
| This branch's `inotifywait-timeout-filtered-events.t` | Not run | 18 of 20 pass |

The two failing cases are case 9 for inotify and case 19 for fanotify. Both
run `--monitor --recursive --include match --timeout 2` while a new directory
appears every 0.5 s. Both exit 124 at the 6 s guard instead of exit 2 at 2 s.

## Cause of the remaining failure

- With `--recursive`, the library passes directory events through the regex
  filter on purpose. The CLI needs them to add watches for new directories. See
  the "Skip regex filtering for directories in recursive mode" branch in
  `next_events_raw()`.
- The CLI loop in `src/inotifywait.rs` then calls `next_event(o.timeout)`
  again. That call starts a new full timeout.
- Each new directory therefore restarts the timeout, even though the CLI
  doesn't print it.

The library fix in #252 can't cover this case. The restart happens in the CLI,
one layer above the library.

## Status of this branch

- PR #252 fixes the main bug in issue #243. The reproduction passes on
  upstream `master`.
- This branch's PR can't be opened as drafted. It conflicts with the merged
  library change.
- The recursive monitor case is still open upstream. A follow-up needs a fix in
  `src/inotifywait.rs` and cases 9 and 19 from this branch's test.
- Upstream's library has no wait function that takes a deadline. This branch
  added one. A follow-up has to add one or find another way to carry the
  deadline across CLI calls.

## Decision for the user

Choose one:

- **Retire the work.** Accept that the recursive monitor case stays open.
- **File a follow-up issue.** Use the draft below.
- **Open a follow-up PR.** A new task would rebase the CLI part of this branch
  onto upstream `master`. It would add only cases 9 and 19, or a sharness test
  in the style of `inotifywait-filtered-timeout.t`.

## Proposed follow-up issue

**Title:** `inotifywait -m -r --include --timeout` never times out while new
directories appear

**Body:**

> After #252, filtered events no longer restart `--timeout`. One case remains.
> With `--monitor --recursive --include`, each new directory still restarts the
> timeout. The directory doesn't match the include pattern and isn't printed.
>
> Reproduction on `master` (6ccd641):
>
> ```sh
> mkdir -p /tmp/w
> (while sleep 0.5; do mkdir "/tmp/w/d$RANDOM"; done) &
> timeout 6 inotifywait -m -r --include match --timeout 2 /tmp/w
> echo "exit $?"   # Prints 124. Expected 2 after about 2 seconds.
> kill %1
> ```
>
> The library lets directory events through the regex filter in recursive mode,
> so that the tool can watch new directories. The main loop in
> `src/inotifywait.rs` then calls `next_event(o.timeout)` with the full timeout
> again. The fix needs a deadline that persists across those calls and resets
> only after an event the tool reports.

The reproduction in this issue draft was run verbatim on a build of 6ccd641 in
the container. It printed "Watching new directory" for each directory and
exited 124.
