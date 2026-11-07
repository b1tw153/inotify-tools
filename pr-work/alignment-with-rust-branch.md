# Aligning the `cpp` and `master` fixes for #243

Two branches fix #243 independently:

- **C++:** `worker/inotify-tools-cpp-timeout`, based on `cpp` at 440ad5f. This
  branch.
- **Rust:** `worker/inotify-tools-rust-timeout`, based on `master` at e763f49.

This note lists the differences between them. It proposes changes so that the
two PRs read as if one author wrote them. Neither branch has changed yet. Items
marked **Decision** need the user.

All measurements below ran in the branches' `debian:bookworm-slim` images on
2026-11-04, unless a section gives another date. The probe scripts are not
committed.

## Work plan for this branch

The user decided on 2026-11-05 to make the alignment changes on this branch
first. The Rust branch follows later. Each unit ends in a commit.

1. Merged reproduction script. Done, see section 2.
2. Merged spec. Done, see section 3.
3. Regression test (`test-writer`). Use the Rust structure and add the C++ cases
   it lacks. Add the six Rust C API cases to `test.cpp`. Done, see section 4.
4. Library documentation and code comments (`implementer`). Use the shared
   wording and the term "filtered events". Rewrap the comment that
   `clang-format` flags. See sections 5 and 8. Done, see section 5.
5. `code-critic` review of the whole fix and test, including 9623101 and
   cc39667. Handle its findings. Done 2026-11-06, see "Code review" below.
6. PR draft. Apply section 6, fold in the `-m -r` scope and the new
   measurements, and retire `issue-recursive-monitor-timeout.md`. Done
   2026-11-06, see sections 6 and 7.

## 1. Scope: unrequested events with `-m -r`

This is the largest difference.

- **Rust:** The spec counts "an event of a type the user didn't request, which
  the tool only uses internally" as a filtered event. The fix changes the main
  loop in `src/inotifywait.rs`. It keeps one deadline across calls and resets it
  only after a reported event.
- **C++:** The spec lists this case as out of scope. The fix changes only the
  library. `pr-work/issue-recursive-monitor-timeout.md` drafts a separate issue
  for it.

Measured with `inotifywait -m -r -t 2 -q -e modify` while a file is created
every 0.5 s. A guard kills the process at 8 s.

| Build | Exit | Time |
| :- | :- | :- |
| Bookworm package 3.22.6.0-4 | Killed (124) | 8.0 s |
| `cpp` with this branch's fix | Killed (124) | 8.0 s |
| `master` at e763f49 | Killed (124) | 8.0 s |
| Rust branch | 2 | 2.0 s |

The `cpp` result comes from the issue draft. The other three are new.

**Resolved 2026-11-04:** The user chose to port the Rust main-loop change.
Commits a800fb4 (spec R19–R27), cc39667 (test) and 9623101 (fix in
`src/inotifywait.cpp`) do this. The fixed build exits with status 2 after 2.0 s
in the case above.

The code review, the PR draft update and the test rewrite in section 4 handled
the follow-up items from this port.

The options were:

- **Extend the C++ fix (recommended).** Port the Rust main-loop change to
  `src/inotifywait.cpp`. This is the first outcome the issue draft proposes. The
  C++ library API takes whole seconds and has no deadline form. One untested
  approach computes the seconds left before each `inotifytools_next_event()`
  call and rounds a part second up. Then drop the issue draft and move the
  measurements into the PR.
- **Narrow the Rust fix.** Remove the `orig_events` part of the deadline reset.
  Keep only the hidden-directory part, which the C++ library already handles.
  File the issue draft against both branches.

Either way, the C++ issue draft is out of date. It says `master` was not tested.
The table above shows that `master` has the bug and the Rust branch fixes it.

### Hidden directory events

The Rust test has a case for `--monitor --recursive --include` with a new
directory every second. On `master`, directory events pass the library filter in
recursive mode, because of commit 3e09f13. On `cpp`, the library filters them,
so the C++ library fix covers this case.

| Build | Exit | Time |
| :- | :- | :- |
| Bookworm package 3.22.6.0-4 | Killed (124) | 8.0 s |
| `cpp` with this branch's fix | 2 | 2.0 s |

The C++ test has no such case. Add it, so that both tests cover the same cases.

## 2. Reproduction script

Both scripts are `pr-work/repro.sh` and take the `inotifywait` binary as an
argument. Their parameters differ.

| Item | C++ | Rust |
| :- | :- | :- |
| `--timeout` | 2 s | 3 s |
| Guard | 6 s | 8 s |
| Late tolerance | 1 s | 2 s |
| Early tolerance | 100 ms | None |
| Clock | `$EPOCHREALTIME` | `date +%s%3N` |
| Output option | `-q` | `-qq` |
| Matching-event case | Yes | No |
| Control failure | Counts as a failed case | Exits 2 |
| Exit 2 means | Usage error | Control or setup failed |

**Proposal:** Use one script on both branches. Take the Rust exit codes, which
separate a broken setup from the bug. Add the C++ matching-event case. Use the
parameters in section 3. Quote the same numbers in both PR drafts.

**Done 2026-11-05:** `pr-work/repro.sh` on this branch is now the merged script.
It is the Rust script plus the C++ matching-event case. It uses the Rust
parameters: `--timeout 3`, an 8 s guard, a 2 s late tolerance, no early bound,
`date +%s%3N` and `-qq`. A failed matching-event case exits 1. Copy the script
to the Rust branch unchanged.

Results in the bookworm container:

| Build | Exit | `--include` | `--exclude` | Appropriate event |
| :- | :- | :- | :- | :- |
| Bookworm package 3.22.6.0-4 | 1 | Killed at 8.0 s | Killed at 8.0 s | Exit 0 at 1.0 s |
| `cpp` at 440ad5f | 1 | Killed at 8.0 s | Killed at 8.0 s | Exit 0 at 1.0 s |
| This branch | 0 | Exit 2 at 3.0 s | Exit 2 at 3.0 s | Exit 0 at 1.0 s |

The control case exited 2 at 3.0 s on all three builds. `pr-draft.md` still
quotes the old script's numbers. Update it in the PR draft unit.

## 3. Specification

The two specs state the same contract from the same man page text. Their
structure and terms differ.

| Item | C++ | Rust |
| :- | :- | :- |
| Event the tool reports | "Delivered event" | "Appropriate event" |
| Requirements | R1–R18 | Six numbered behaviors and a test table |
| Late tolerance | 1 s, tests may allow more | 2 s |
| Early tolerance | 100 ms | None, "doesn't fire early" |
| Measured behavior section | Yes | No, in `implementation-notes.md` |
| Unrequested internal events | Out of scope | Filtered events |

**Proposals:**

- Use "appropriate event", the man page's term, in both specs. Keep "filtered
  event" for the rest. Both specs already use it.
- Use one tolerance. The Rust value of 2 s late suits CI. Keep the C++ 100 ms
  early bound only if a test checks it. Neither sharness test does.
- Align the scope with the decision in section 1.
- Keep the library sections apart where the libraries differ. See section 5.

**Done 2026-11-05:** `pr-work/spec.md` on this branch is now the merged spec. It
uses the Rust layout and terms, and it keeps the C++ requirements. It counts
unrequested events as filtered events and gives them their own requirements, R9
to R13. Its case table lists the sharness and C API cases for unit 3. Its
"Branch notes" section holds the differences between the branches, so the file
can go to the Rust branch unchanged. The Rust branch's `implementation-notes.md`
measurements now also appear in the spec's measurement table.

The new `cpp` row in that table, `--exclude -t 2` with continuous filtered
events, was measured on 2026-11-05. The bookworm package and 440ad5f were both
killed at 8.0 s. This branch exits with status 2 at 2.0 s.

## 4. Regression test

Both branches add `t/inotifywait-timeout-filtered-events.t`. The file names
match. The contents don't.

| Item | C++ | Rust |
| :- | :- | :- |
| `test_description` | "Filtered events do not extend the --timeout period (issue #243)" | "--timeout is not restarted by filtered events", and a paragraph |
| Structure | Two parallel setup steps, then one check per case | One sequential step per case, in a `run_suite` function |
| Clock | `date +%s`, 1 s resolution | `date +%s%N` and a `TIMING` prerequisite |
| Guard | Hand-written `bounded()` | `timeout` command |
| Filtered events | Renames, `-e moved_to` | `touch`, default events |
| Test count | 13 for inotify, 2 of them setup steps, and 3 for fanotify | 10 per backend |
| Run time | About 14 s in all | About 21 s per backend |
| C API cases | None | Six in `libinotifytools/src/test.cpp` |

Case coverage:

| Case | C++ | Rust |
| :- | :- | :- |
| `--include`, `--includei`, `--exclude`, `--excludei` | Yes | Yes |
| Continuous filtered events | Yes | Yes |
| Appropriate event among filtered events, exit 0 | Yes | Yes |
| `--monitor`, filtered events only | No | Yes |
| `--monitor`, appropriate event restarts the period | Yes | Yes |
| `--monitor`, a stream of appropriate events | Yes | No |
| `--monitor --recursive --include`, new directories | No | Yes |
| No filter and no events | Yes | No |
| `--timeout 0` | Yes | Yes |
| No `--timeout` option | Yes | No |

**Proposal:** Use the Rust structure on both branches. It is shorter, it has a
millisecond clock, and it runs every case under fanotify. Add the C++ cases it
lacks: the `--monitor` stream, no filter, and no `--timeout`. Use the same
`test_description` and case names on both branches. This also closes these C++
test gaps from earlier reports:

- The 1 s timing resolution.
- `sleep 0.1` without a prerequisite check.
- fanotify coverage of only 3 cases.

**C API cases:** I applied the six Rust `test.cpp` cases to the C++ branch. The
only change was the C++ two-argument form of
`inotifytools_ignore_events_by_regex()`. All six pass on the C++ fix. All six
also pass with the unfixed 440ad5f library. On `cpp` they guard the zero-timeout
behavior, but they don't detect the bug. Add them to the C++ branch anyway, so
both branches test the same C API contract.

**Done 2026-11-06:** `test-writer` rewrote the test from the merged spec in the
Rust structure. It has 18 cases per backend, one for each row of the spec's case
table. The case names match the Rust test where the cases match. The six C API
cases are in `test.cpp`.

Differences from the Rust test to carry over to the Rust branch:

- Cases that only wait for the exit use a 1 s timeout. Cases that restart the
  period, and the new-directory case, use 2 s. A 1 s timeout with a new
  directory every second didn't detect the bug.
- Restart cases record the time of the appropriate event in the file `evt`. They
  check the exit against that time.
- Generators that make an event at a set time first wait for "Watches
  established." on standard error. Those cases run without `--quiet`.
- The fanotify suite runs the recursive cases only if `fanotify_supported -m -r`
  succeeds.

Results in the bookworm container. The final R13 change ran once per backend.
The other runs came just before it.

| Build | Sharness test | C API test |
| :- | :- | :- |
| 440ad5f, unfixed | 10 of 18 fail: 1–5, 7, 8, 13, 14, 15 | Pass |
| 4f45c55, library fix only | 2 of 18 fail: 14, 15 (R9, R11) | Pass |
| This branch | 18 of 18 pass, 5 runs | Pass |
| This branch, root with fanotify | 36 of 36 pass, 4 runs | Not run |

The full `t/` suite passes 30 of 30 on this branch, and `make check` passes. A
run of the new test takes about 45 s per backend.

Known timing limits of the test:

- The `-qq` case can't wait for the watches, because the program prints nothing.
  Its event comes 1 s after the program starts.
- The new-directory case has about 0.5 s between steps. A loaded machine could
  break that margin.
- The tests don't cover R8 and L7, the monotonic clock. They also don't cover
  L2, L3 for negative values, or L5.

## 5. Library documentation

Both fixes change the same two Doxygen blocks. On `cpp` the blocks are in
`inotifytools.cpp`. On `master` they are in `inotifytools.h`. The wording
differs.

| Text | C++ | Rust |
| :- | :- | :- |
| `@note` | "Such events do not restart the @a timeout period. Each call to this function starts a new @a timeout period." | "Those events do not restart the @a timeout period. The function returns NULL once @a timeout seconds have passed since the call began, unless an event that passes the filter is available first." |
| `next_event` `@param timeout` | Adds a sentence for a positive value. "Zero or negative" blocks. | "Zero or negative" blocks. No sentence for a positive value. |
| `next_events` `@param timeout`, zero | "the function does not block" | "does not block", and states the one-read limit |
| `@return` | Adds "After a timeout, inotifytools_error() is 0." | Unchanged |

**Proposal:** Use the same sentences in both. Start from the Rust `@note`, which
states when the function returns. Add the C++ sentence "Each call to this
function starts a new @a timeout period." Add the C++ positive-value `@param`
sentence and the `@return` sentence to both.

The zero-timeout text should stay different only where the code differs. From
reading the code, which I have not tested:

- **Rust:** A zero timeout reads the kernel queue once. If that read holds only
  filtered events, the call returns `NULL`.
- **C++:** After each filtered event, the code jumps back and calls `select()`
  with a zero timeout again. A zero timeout keeps reading while events are
  queued. The fix doesn't change this.

Code comments also use different terms. The C++ comments say "ignored events",
after `inotifytools_ignore_events_by_regex()`. The Rust comments say "events
skipped by the filters". Pick one. "Filtered events" matches the specs, the
tests and the PR titles.

**Done 2026-11-06:** `implementer` aligned the C++ documentation with spec D1 to
D3.

- Both `@note` blocks use the D1 text.
- The zero-timeout `@param` text of `inotifytools_next_events()` states only
  what L4 says and the C API tests check. It doesn't describe the read loop.
- The fix's code comments in `inotifytools.cpp` and `src/inotifywait.cpp` say
  "filtered events".
- `clang-format` reports no changes in either file.

The reproduction passes, `make check` passes, and the `t/` suite passes 30 of
30, with all 18 cases of the new test.

Carry these to the Rust branch:

- Add "Each call to this function starts a new @a timeout period." to both
  `@note` blocks.
- Add the positive-value `@param` sentence and the `@return` sentence from D1.
- Rename "events skipped by the filters" to "filtered events" in the Rust
  comments.

## 6. PR drafts

| Item | C++ | Rust |
| :- | :- | :- |
| Title | "Stop filtered events from extending `--timeout`" | "Don't restart --timeout on filtered events" |
| Opener notes heading | "Notes for the opener. These aren't part of the PR." | "Before opening the PR" |
| Body sections | Problem, Fix, Tests, Limitations | Intro, Changes, Library API, Tests, Out of scope |
| Squash advice | None | Two commits, test then fix |
| Results table columns | Build, Reproduction script, New test | Build, New sharness test, Reproduction |

**Proposals:**

- Use one title on both, with the branch in the opener notes. For example:
  "Don't restart `--timeout` on filtered events".
- Use one section layout. The Rust layout has a separate "Library API" section,
  which suits the documented behavior change on both branches.
- Give the same squash advice on both. The C++ branch has the same history
  shape: one test commit, one fix commit and review follow-ups.
- Cross-reference the two PRs. Each should say that the other branch has the
  same bug and a matching fix.
- Use the same results table columns, and the same build names.

**Done 2026-11-06:** `pr-work/pr-draft.md` on this branch now follows the Rust
draft's layout and wording. It has the same title, opener notes heading, body
sections, squash advice and table columns. It folds in the `-m -r` scope, the
merged reproduction's numbers and the results at 845fdc5. The `-lrt` note moved
into "Changes". The note on building `fsnotifywait` is gone, by the user's
decision of 2026-11-05.

Carry these to the Rust draft:

- Add the cross-reference sentence and a `CPP_PR_LINK` placeholder, with an
  opener note to fill it in.
- Name the build in the reproduction table with its version, "Debian bookworm
  `inotify-tools` package 3.22.6.0-4".
- Add the `-m -r` unrequested-event source to the body. The Rust draft names
  only the hidden-directory events.
- List the added test cases from the merged spec: the monitor stream, no filter,
  no `--timeout` option and the four new `-m -r` cases.
- Drop the opener note on the omitted `--timeout` gap. The merged test covers
  it.
- Mention that each call starts a new period and the `@return` sentence under
  "Library API", once the Rust docs adopt them.

## 7. Issue drafts

- **C++:** `issue-recursive-monitor-timeout.md`, for `-m -r`. Removed
  2026-11-06. The PR now covers that case, and its measurements are in the PR
  draft.
- **Rust:** `issue-recursive-include-exit0.md`, for `-r --include` exiting 0. It
  applies only to `master`, because `cpp` lacks commit 3e09f13.

Both use "Notes for the opener" and an "Issue text" section, so their layout
already matches.

## 8. Other C++ items found in this review

- **`clang-format` change needed.** The repository's `.clang-format` rewraps one
  comment in the fix at `libinotifytools/src/inotifytools.cpp` lines 1544–1545.
  The line "and must not restart the period. Do not modify deadline after
  setjmp." is longer than 80 columns with 8-column tabs. The unfixed file needs
  no changes. Rewrap the comment before opening the PR. Done 2026-11-06.
- **No new compiler warnings.** I built the library with
  `-Wall -Wextra -Wmaybe-uninitialized -Wclobbered` at the fix and at 440ad5f.
  Both builds give the same 14 warnings, all outside the changed code. This
  closes an earlier `implementer` open question.
- **`-lrt` on old glibc.** `clock_gettime()` needs `-lrt` before glibc 2.17. The
  user decided on 2026-11-05 to leave the check out and note it in the PR.
  `pr-draft.md` has the note. The Rust fix uses `std::time::Instant` and has no
  such limit.
- **fanotify build bugs on `cpp`.** An earlier report asked whether to report or
  fix these. The user has not answered. In `configure.ac`, the fanotify
  `AC_ARG_ENABLE` sets `DOXYGEN_ENABLE` instead of `ENABLE_FANOTIFY`. In
  `src/Makefile.am`, `fsnotifywait_CPPFLAGS` replaces the include path in
  `AM_CPPFLAGS`.

## Code review

`code-critic` reviewed the diff from 440ad5f on 2026-11-06. It found no blocking
issues. Commits 3d15b68, fdd236b, e795d4c and 845fdc5 handle its findings.

- The incomplete-event comment says the code jumps back to `setjmp` and keeps
  the deadline.
- The helper `deadline_passed()` is now `time_until_deadline()`. It borrows in
  nanoseconds before it converts to microseconds.
- The `setjmp` comment says why `deadline` must not change after `setjmp`.
- The `inotifywait.cpp` comment defines an appropriate event and names the
  events that `-m -r` adds.
- The C API tests fail at setup when a file can't be opened, and they name their
  time limits. The `.t` helpers use descriptive names and report a watch that
  never starts.
- `clang-format` reports no changes in the three changed C++ files.

Results in the container at 845fdc5:

| Build | Reproduction | New `.t` test | C API test |
| :- | :- | :- | :- |
| 440ad5f with the new tests | Fail | 20 of 36 fail | Pass |
| 845fdc5 | Pass | 36 of 36 pass | Pass |

The new `.t` test takes about 42 s for inotify alone and 84 s with fanotify. The
rest of the `t/` suite passes as a normal user. As root,
`fsnotifywait-subtree.t` fails 1 of 3 cases at 440ad5f and at 845fdc5 alike.

Deferred findings:

- **Run time.** The reviewer asked whether 84 s fits the project's CI budget.
  The PR draft should mention it so that maintainers can ask to trim cases.
- **`-lrt` on old glibc.** Already noted in the PR draft.

Carry to the Rust branch: nothing. The changes are specific to the C++ code.
