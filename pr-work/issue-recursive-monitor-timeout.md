# Proposed issue: unrequested events extend `--timeout` with `-m -r`

Notes for the opener. These aren't part of the issue.

- **Related:** #243 and the PR that fixes it on the `cpp` branch. That PR stops
  filtered events from extending `--timeout`. It doesn't change this case.
- **Branches:** The `cpp` branch at 440ad5f and the PR branch both show this
  behavior. Upstream `master` adds the same events in `src/inotifywait.rs`. I
  haven't tested a `master` build.
- **Before filing:** Decide which outcome to propose. The issue below lists the
  options without picking one.

## Issue text

### Title

`inotifywait -m -r --timeout` never times out while files are created

### Description

`inotifywait --timeout` documents that it exits "if an appropriate event has not
occurred within `<seconds>` seconds". With `--monitor` and `--recursive`, events
that the user didn't request restart the timeout. If files keep being created in
the watched tree, the timeout never fires. `inotifywait` prints nothing during
that time.

`inotifywait` needs `create`, `moved_to` and `moved_from` events to watch new
directories under the tree. With `-m -r`, `src/inotifywait.cpp` adds these
events to the watch mask:

```c
if (monitor && recursive) {
	events = events | IN_CREATE | IN_MOVED_TO | IN_MOVED_FROM;
}
```

Each call to `inotifytools_next_event(timeout)` returns these events. The main
loop prints an event only if it matches the requested events. It then calls
`inotifytools_next_event(timeout)` again with a new timeout period. An
unrequested event therefore restarts the timeout in the same way as a requested
one.

### Steps to reproduce

```sh
d=$(mktemp -d)
( for i in $(seq 14); do touch "$d/f$i"; sleep 0.5; done ) &
timeout 8 inotifywait -m -r -t 2 -q -e modify "$d"
echo "exit status: $?"
```

### Expected result

`inotifywait` exits with status 2 about 2 seconds after it starts. No `modify`
event occurs, and the user didn't ask for `create` events.

### Actual result

`inotifywait` is still running when `timeout` kills it after 8 seconds. The
exit status is 124. It prints no events.

### Measurements

I ran each case in a `debian:bookworm-slim` container. A background loop
changed the watched directory every 0.5 seconds for 7 seconds. GNU `timeout`
killed `inotifywait` after 8 seconds. Every case used `-t 2 -q -e modify` and
printed no events. The two builds were Debian's package 3.22.6.0-4 and the
`cpp` branch with the fix for #243.

| Options | Change in the directory | Package 3.22.6.0-4 | `cpp` with the #243 fix |
| :- | :- | :- | :- |
| `-m -r` | Create a file | Killed at 8 s | Killed at 8 s |
| `-m -r` | Rename a file | Killed at 8 s | Killed at 8 s |
| `-m -r` | Create a file in a subdirectory | Killed at 8 s | Killed at 8 s |
| `-m -r` | Touch a subdirectory | Exit 2 at 2 s | Exit 2 at 2 s |
| `-m` | Create a file | Exit 2 at 2 s | Exit 2 at 2 s |
| `-r` | Create a file | Exit 2 at 2 s | Exit 2 at 2 s |
| `-m -r --exclude 'f[0-9]+$'` | Create a file | Killed at 8 s | Exit 2 at 2 s |

Only the combination of `-m` and `-r` shows the problem. It needs an added event
type, so touching a directory doesn't trigger it. The last row shows that the
#243 fix covers an added event when a filter rejects it.

### Possible outcomes

- Keep the timeout period running across events that `inotifywait` didn't
  print. The main loop could compute one deadline when it starts waiting. It
  would restart the deadline only after a printed event. It would pass the time
  left to `inotifytools_next_event()`.
- Treat the behavior as intended and document it under `--timeout` and
  `--recursive` in the man page.
