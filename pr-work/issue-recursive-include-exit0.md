# Proposed issue: `-r --include` exits 0 silently on a new directory

Notes for the opener. These aren't part of the issue.

- **Related:** #243 and its PR. That PR fixes `--timeout` with filters. It
  doesn't change this case.
- **Origin:** Commit 3e09f13 ("improvement: allow recursive watch with
  --include") added the behavior. It first shipped in 4.25.9.0. The `cpp` branch
  at 440ad5f doesn't have that commit.
- **Tested:** Debian bookworm's `inotify-tools` 3.22.6.0-4 and a build of
  `master` at e763f49, in a `debian:bookworm-slim` container. The PR branch for
  #243 behaves the same as `master`.

## Issue text

### Title

`inotifywait -r --include` exits 0 with no output when a directory is created

### Description

Without `--monitor`, `inotifywait --recursive --include <pattern>` exits with
status 0 and prints nothing when a directory is created in the watched tree. The
directory name doesn't match the pattern. `inotifywait` should keep waiting for
an event that matches, as it does without `--recursive`.

The same happens with `--includei`. It needs the default event set or an event
list that includes `create` or `moved_to`.

### Steps to reproduce

```sh
d=$(mktemp -d)
( sleep 1; mkdir "$d/sub"; sleep 1; touch "$d/a.txt" ) &
timeout 6 inotifywait -r --include '\.txt$' "$d"
echo "exit status: $?"
wait
rm -rf "$d"
```

### Expected result

`inotifywait` ignores the new directory. It prints the `CREATE` event for
`a.txt` after about 2 seconds and exits with status 0. Version 3.22.6 behaves
this way.

### Actual result

`inotifywait` exits after about 1 second with status 0 and prints nothing. It
misses `a.txt`.

| Command | 3.22.6 | `master` |
| :- | :- | :- |
| `-r --include '\.txt$'` | Prints `a.txt` at 2 s | Exit 0 at 1 s, no output |
| `-r --include '\.txt$' -e create` | Prints `a.txt` at 2 s | Exit 0 at 1 s, no output |
| `-r --includei '\.TXT$'` | Prints `a.txt` at 2 s | Exit 0 at 1 s, no output |
| `-r --include '\.txt$' -e close_write` | Prints `a.txt` at 2 s | Prints `a.txt` at 2 s |

### Cause

Commit 3e09f13 lets directory `create` and `moved_to` events pass the regex
filter in recursive mode. `--monitor` needs them to add watches on new
directories. The library function `next_events_raw()` in
`libinotifytools/src/inotify.rs` passes them through for every recursive watch,
with or without `--monitor`.

The main loop in `src/inotifywait.rs` hides directory events when an include
filter is set. Without `--monitor`, it still ends the loop on the hidden event.
The requested events include `create`, so the exit status is 0.

A possible fix is to keep waiting after a hidden event when `--monitor` isn't
set. Another is to pass directory events through the filter only in monitor
mode.
