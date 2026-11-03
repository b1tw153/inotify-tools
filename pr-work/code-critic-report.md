# Code review: `--timeout` filtered-events fix (branch `worker/inotify-tools-rust-timeout`)

Reviewed `master..HEAD` excluding `pr-work/`. I read `pr-work/spec.md` for the
contract. I did not build or run anything, so no claim here is a measurement.

## Verdict

No `blocking` findings. No `should-fix` findings. All findings are `note`.

## Verdicts on the six questions

| # | Question | Verdict |
| :- | :- | :- |
| 1 | Repeated code in `test.cpp` | Leave as is. Optional small helper, see N1. |
| 2 | `verify2(..., e->name)` as failure message | Leave as is. It matches neighbouring tests. |
| 3 | Rustdoc link to a `pub(crate)` item | Leave as is. It is a false alarm. |
| 4 | Unquoted `$backend` (SC2086) | Leave as is. Add a one-line comment, see N5. |
| 5 | Top-level `export LD_LIBRARY_PATH` | Leave as is. |
| 6 | No second kernel read after the deadline | Leave as is. Optionally add a doc caveat, see N3. |

### 1. Repetition in `test.cpp`

The setup is already shared through `SETUP_NOISE_FILTER`
(`libinotifytools/src/test.cpp:347`) and the `write_close_file` helper. It has
to be a macro because `verify` does `return`.

What remains is the same four-step pattern in four tests (lines 394, 412, 429
and 448):

1. Take a start time.
2. Call the API.
3. Compute the elapsed time.
4. Make two or three checks.

The file's existing tests are flat and repetitive in the same way.
`tst_inotifytools_snprintf` is an example. A fixed-shape helper would hide which
API call each test exercises. Repeating the pattern is the lesser harm, so leave
it.

### 2. `e->name` as failure message

Lines 365, 382 and 386 pass the actual event name as the message. This matches
`event_to_str` and `tst_inotifytools_snprintf` in the same file, which pass the
produced string as the message. `_verify` prints the message through `%s`, so
there is no format-string hazard. Seeing which file arrived is the useful fact
on a failure.

One edge case: if `e->len` were 0, `e->name` would be an empty or unrelated byte
area. Each failing test would then print garbage, but only on a failure that has
already happened. This does not need a change.

### 3. Rustdoc link in `next_events_until`

The doc comment at `libinotifytools/src/inotify.rs:1405` links
`Inotifytools::next_events_raw`. The linking item is `pub(crate)` too. rustdoc's
`private_intra_doc_links` lint fires only when a public item's docs link a
private one. Both items are crate-private, so the link is fine and resolves in
`--document-private-items` output.

### 4. Unquoted `$backend`

The word splitting is intended. It is also the repository's idiom. Neighbouring
tests do the same with `../../src/$*`, for example
`t/inotifywait-no-event-occured.t:11` and
`t/inotifywait-format-watched-dir.t:22`. Their callers pass
`fsnotifywait --fanotify` as separate words.

Quoting would break the `--fanotify` case. Per the project-first rule, follow
the neighbours. See N5 for a small comment that would help readers.

### 5. `LD_LIBRARY_PATH` placement

Neighbours export it inside each `run_` helper. This file has several helpers
and four call sites that run binaries. One top-level export
(`t/inotifywait-timeout-filtered-events.t:16`) is simpler and equivalent.
Sharness runs each test body in the same shell, so the exported value is
inherited. No project rule requires per-helper export. Leave it.

### 6. No kernel read after the deadline

The behaviour is in `libinotifytools/src/inotify.rs:1459-1465`.

- When the buffer is drained, `polled` is true and the deadline has passed, the
  call returns false.
- A single `read` takes at most `EVENT_SIZE * MAX_EVENTS` bytes. That is 64 KiB,
  which is 4096 events at the minimum 16-byte size and fewer with file names.
- If one read returns only filtered events and the kernel still holds a passing
  event behind them, a zero-timeout call returns NULL.
- The event is not lost. The next call reads it.

This can happen only with more than about 2000 to 4096 filtered events queued at
once. Reading further would reopen the bug that
`pr-work/implementation-notes.md` calls the "continuous stream" trap. `ppoll`
with a zero timeout still reports a non-empty queue as ready, so the loop would
never end. The cap is therefore part of the design, not an oversight.

For nonzero timeouts the deadline has passed anyway, so nothing is wrong. The
only visible mismatch is the header text for `inotifytools_next_events`. It says
a zero timeout "checks once for a queued event". The true statement is "reads
the queue once". See N3.

## Findings

### N1. `note`: lettered case labels are meaningless upstream

- Location: `libinotifytools/src/test.cpp:355`, `:371`, `:392`, `:427`
- Convention: comments state intent and do not point at material the reader
  lacks (C++ Core Guidelines NL.1 to NL.3, from `cpp.md`).
- Problem: "Case (a)" to "Case (d)" come from the task spec. Upstream readers
  have no key, and the two other new tests have no letter.
- Fix: TODO: drop the "Case (x):" prefixes and keep the descriptive sentence.

### N2. `note`: the 0 to -1 mapping is duplicated

- Location: `src/inotifywait.rs:306-309`, compare
  `libinotifytools/src/inotify.rs:1373-1375`
- Convention: no duplicated knowledge (`general.md`: "Simple is better than
  complex").
- Problem: `Inotifytools::next_event` maps zero to "block", and `inotifywait`
  re-implements that mapping in the `new_deadline` closure. The comment explains
  it. The knowledge still lives in two places.
- Fix: TODO: either leave the comment as the single explanation, or add a small
  library helper for "deadline for next_event semantics" and use it in both
  places.

### N3. `note`: doc wording on the zero timeout

- Location: `libinotifytools/src/inotifytools/inotifytools.h` (the
  `inotifytools_next_events` `@param timeout` text) and
  `libinotifytools/src/inotify.rs:1405-1410`
- Convention: docs state exact behaviour (C-LINK / documentation rules from
  `rust.md`; plain `general.md` readability).
- Problem: "checks once for a queued event" overstates the guarantee. One read
  returns at most 64 KiB of events (see question 6).
- Fix: TODO: say "reads the queue once" and note that a passing event behind a
  full buffer of filtered events is returned by the next call.

### N4. `note`: redundant and inconsistent wording

- Location: `libinotifytools/src/inotifytools/inotifytools.h` (the
  `inotifytools_next_event` `@param timeout` text),
  `libinotifytools/src/inotify.rs:1379-1380`
- Problem 1: the header says "zero ... blocks until an event occurs" and then
  "negative ... block until an event occurs" in two sentences. That is two
  sentences for one rule.
- Problem 2: the `next_event_until` doc says "do not" where the neighbouring
  docs say "don't".
- Problem 3: `next_event_until` (public) could link `deadline_after` so readers
  know where a deadline comes from (C-LINK).
- Fix: TODO: write "If timeout is zero or negative, the function blocks until an
  event occurs.", use "don't", and link [`deadline_after`] in the
  `next_event_until` docs.

### N5. `note`: intent of the word splitting is unstated

- Location: `t/inotifywait-timeout-filtered-events.t:135` (`backend="$*"`)
- Convention: explain surprising code (`general.md`: "Explicit is better than
  implicit"). SC2086 applies, but the project idiom wins (see question 4).
- Fix: TODO: add a comment that `$backend` is left unquoted so
  `fsnotifywait --fanotify` splits into command and option.

### N6. `note`: helpers overwrite the caller's `period`, and setup is repeated

- Location: `t/inotifywait-timeout-filtered-events.t:97`, `:110`, `:122`,
  `:136`, and the setup lines in the matching-event, restart and `timeout 0`
  tests
- Convention: POSIX `sh` has no function-local variables. Sharing globals is
  accepted, but readers must know the coupling exists.
- Problem 1: `run_timed` and `case_exit2` assign the global `period`.
  `run_suite` sets the same global to 2. It works because every caller passes
  the same value, but it is fragile.
- Problem 2: three tests repeat
  `rm -rf watched stop && mkdir watched && noise_start ...`, which `case_exit2`
  already does.
- Fix: TODO: use distinct variable names in the helpers (for example `p`), and
  extract a `setup_watch` helper for the repeated lines.

### N7. `note`: run time

- Location: `t/inotifywait-timeout-filtered-events.t:138-208`
- Convention: the spec asks for short run time because CI runs the suite on
  every commit.
- Problem: by my reading of the test, each backend takes about 20 seconds (six
  2-second cases, one 3-second case, one near-1-second case and a restart case
  of about 3 seconds). With fanotify the file takes about 40 seconds. This is an
  estimate, not a measurement.
- Fix: TODO: consider dropping `includei` or `excludei` duplicates from the
  fanotify run, or measure and accept the cost.

### N8. `note`: near-identical names

- Location: `libinotifytools/src/inotify.rs:1411` versus `:1389` and `:1401`
- Problem: `next_event_until` (public), `next_events_until` (crate) and
  `next_events_raw` differ by one letter or a suffix. The existing `next_event`
  and `next_events` already pair this way, so it is consistent.
- Fix: TODO: none required. If renaming is acceptable, give the crate-private
  deadline form a distinct name such as `wait_for_event_until`.

## Checked and found clean

- Minimum Rust 1.63: `Instant::checked_add`, `saturating_duration_since` and
  `Option::map_or` are all available there. The code correctly avoids
  `is_some_and`, which needs 1.70.
- `deadline_after` handles negative values and overflow, and the doc says so.
- The `hidden` restructure in `src/inotifywait.rs` is easier to read than the
  nested `if` it replaces.
- The header's old "non-negative is non-blocking" claim was wrong for
  `inotifytools_next_event`, and the new text fixes it.
- The sharness test follows `fanotify-common.sh` conventions
  (`fanotify_supported`, `test_expect_success`).
- The single-quoted test bodies contain no stray apostrophes.

## Sources

- `/home/kai/.claude/code-critic/general.md`
- `/home/kai/.claude/code-critic/languages/rust.md`, `cpp.md` and `bash.md`. I
  did not fetch the linked online references. I used my own knowledge of the
  Rust API Guidelines, the C++ Core Guidelines and Bash Pitfalls.
- Project conventions came from neighbouring code: the other `t/*.t` tests,
  `t/fanotify-common.sh`, and the existing helpers and macros in
  `libinotifytools/src/test.cpp`. I also read `rustfmt.toml` and `.clang-format`
  as present but did not apply their formatting rules.
- C is covered by the C++ language file. For shell, only `bash.md` applies, and
  the test file is POSIX `sh`.

**Verdict: no blocking findings.**

## Disposition

The worker added this section after the review.

| Finding | Action |
| :- | :- |
| Questions 1 to 6 | Left as is, per the verdicts above. |
| N1 | Fixed. The case letters are gone from the `test.cpp` comments. |
| N2 | Left as is. The comment in `src/inotifywait.rs` explains the mapping. |
| N3 | Fixed. The header and Rust docs say a zero timeout reads the queued events once, up to the buffer size. |
| N4 | Fixed. One sentence for zero or negative, "don't", and a link to `deadline_after`. |
| N5 | Fixed. A comment explains the unquoted `$backend`. |
| N6 | Fixed. Helpers use `p`, and a `setup_watch` helper holds the repeated setup. |
| N7 | Left as is. Measured run time is about 21 seconds per backend, about 42 seconds with fanotify. |
| N8 | Left as is. The names follow the existing `next_event` and `next_events` pair. |
