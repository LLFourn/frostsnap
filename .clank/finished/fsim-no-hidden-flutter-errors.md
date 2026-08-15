# fsim-no-hidden-flutter-errors
# fsim-no-hidden-flutter-errors — a Flutter error must fail the test that caused it

## Problem

The harness has no `FlutterError.onError`, no `PlatformDispatcher.instance.onError`, and
no `ErrorWidget.builder`. Verified: neither `test_driver/` nor `lib/main.dart` installs
any of them.

App stderr IS captured — `[app:err] …` into `_appLog` (`sim_harness.dart:1144`) — and
dumped into `error.txt` when a scenario fails. But `_appLog` is used for exactly three
things: appending, trimming to 400 lines, and printing into diagnostics. **Nothing ever
fails a test because of it.**

So a `RenderFlex overflowed`, a `setState() called after dispose()`, an assertion in
`build`, or an exception inside a builder prints its red block, the app keeps running, and
the scenario reports PASS. The only way anyone sees it is by reading the log of a test
that already failed for another reason — and the 400-line cap can evict it before that log
is ever written.

The red ERROR WIDGET is the sharpest case. When a build throws, Flutter swaps that subtree
for `ErrorWidget`. The app stays up, the semantics tree changes shape, and the test either
fails later with a confusing label miss or — worse — passes, because whatever it asserted
next happened to still be present. A screen that is visibly broken to a human is invisible
to the suite.

Direct evidence from the session that produced this plan: `[app:err] … _AssertionError …
'No root widget is attached'` was only noticed because someone happened to be reading a
failure artifact for an unrelated reason. It turned out benign. A real defect in the same
position would have shipped green.

This is the same defect class the two preceding plans fixed at every inner layer — a
mechanism reporting health it never checked — sitting at the outermost one.

## Model

TWO sources and one renderer — not three sources. Getting that wrong double-counts:

- **`FlutterError.onError`** — the AUTHORITATIVE record for framework errors: build/layout/
  paint, assertions, the "EXCEPTION CAUGHT BY …" blocks.
- **`PlatformDispatcher.instance.onError`** — uncaught asynchronous errors that escape
  their zone and would otherwise only reach the console.
- **`ErrorWidget.builder`** is NOT a third source. A build failure is reported through
  `FlutterError.onError` FIRST and then rendered through the builder with the same
  `FlutterErrorDetails`. Recording in both places yields two logical events for one defect
  and makes consumption ambiguous. The builder wraps the previous builder to add a stable
  semantic marker — so a wrecked subtree is targetable and greppable — and records
  NOTHING. One build throw must produce exactly one captured error.

Capture must be STRUCTURED, not a string buffer. The existing failure is precisely that
errors live only in stderr text with a line cap; the harness asks the app for events and
gets a list, so detection is deterministic and survives log trimming. Every hook chains to
the handler it replaced, or the console output a human reads disappears.

### The transport must not lose events

A read endpoint plus a separate clear endpoint has a race: an error arriving between the
two is discarded, and the errors most worth catching are the ones racing a command. The
app exposes ONE atomic drain — returns the pending events and clears them in the same
call — or monotonic event ids with a harness-held cursor. No read-then-clear pair.

### One boundary owner, beneath both wrappers

`_rawDriverCall` and `_rawRequestData` own the check, draining after the operation whether
it SUCCEEDED or FAILED, so an error raised by a command that returned normally is still
attributed to it and the originating verb is preserved.

The drain itself must be RAW and uninstrumented. A drain that went through the checked
path would create another checked boundary and recurse — the same reason failure
diagnostics already take the raw transport rather than the gated one.

### An expectation is an active consumer, not a mute button

`expectAppErrors(pattern)` CONSUMES matching events within its scope. Events that do not
match still fail, inside the scope or out. A scope that closes without having matched
anything FAILS — the same rule `ExpectedFailure` already applies, and what keeps an
allowance from rotting into blanket suppression.

## Milestone 1 — capture every Flutter error, structurally

- Install all three hooks in the sim app before `app.main()`, each chaining to the handler
  it replaced so console output is unchanged for a human reader.
- Record `{id, kind, summary, library, context, stack, sinceStartMs}` in an in-app list,
  drained ATOMICALLY over driver-data (one take-and-clear call, or ids plus a cursor).
  No read-then-clear pair, and no stderr parsing anywhere in the harness.
- `ErrorWidget.builder` wraps the previous builder to render a widget carrying a stable
  semantic label — so a wrecked subtree is targetable — and records NOTHING, because
  `FlutterError.onError` has already recorded that same failure.
- Unit coverage for the classification and the expectation matcher, dependency-free in the
  style of `label_resolve.dart` / `driver_phase.dart`.

## Milestone 2 — an unexpected error fails the scenario, at the command that caused it

- `_rawDriverCall` and `_rawRequestData` own the drain, after success AND after failure,
  so an error raised by a command that returned normally is still attributed to it. The
  drain uses the raw uninstrumented transport, so checking cannot recurse into itself.
- Failure names the command it followed and carries the app's own summary and stack.
- Also drained at scenario end, so an error after the last command cannot escape.
- `expectAppErrors(pattern)` consumes matching events within its scope; non-matching
  events fail anyway; a scope that closes unmatched FAILS.
- Decide the startup `set_semantics … No root widget is attached` assertion explicitly.
  DISPOSITION, verified rather than inferred: it is still observed in the app log, and it
  does NOT reach the recorder. `FlutterDriverExtension` catches it as a COMMAND error
  ("Uncaught extension error while executing set_semantics") and returns it to the driver;
  it never passes through `FlutterError.onError`. The harness's startup retry already
  absorbs it. So NO expectation is installed — one would never fire, and by this plan's own
  rule a stale expectation fails.
- Deterministic fixtures, one per source: a widget that throws in `build` (red screen), an
  async throw that escapes its zone, and a framework assertion. Each must fail its
  scenario with the app's error surfaced.
- NEGATIVE CONTROL, required: with the hooks removed, the fixture scenarios must FAIL —
  they assert that provoking an error causes a failure, so removing the detection makes
  that assertion fire ("expected a failure, got none"). A regression that survives its own
  subject being deleted does not count as coverage.

## Milestone 3 — run the existing suite and FIX what it finds

- Run the full suite with detection on. Expect it to go red: a detector that has never run
  is looking at code nobody has ever checked this way.
- FIX what it finds, in this plan. A defect the detector caught is not someone else's
  problem to schedule: the point of building it was to stop shipping over these, and a
  finding parked in a queue is indistinguishable from a finding suppressed.
- Fix the CLASS where the finding names one. A single bad call site usually means the
  pattern is available to every neighbouring one.
- Something genuinely benign gets a named expectation with a written reason. That is a
  judgement to be argued in the commit, not a default — and because an expectation that
  never fires FAILS, a benign-looking finding cannot be parked behind one.

## Acceptance

- A scenario whose app throws in `build`, throws asynchronously, or trips a framework
  assertion FAILS, and the failure text carries the app's error and stack.
- ONE build throw produces exactly ONE logical captured error — the red widget renders and
  is targetable, but does not double-count the failure that caused it.
- An error raised between two drains is never lost: with an error arriving while a command
  is in flight, it is still reported and attributed.
- The drain does not itself trip the checker (no recursion) and does not perturb the verb
  attributed to a failure.
- With the hooks removed those same scenarios FAIL, and on the detection assertion rather
  than incidentally — proving the coverage bites.
- An error the app raises but no scenario observes still fails at scenario end.
- A deliberate provocation inside `expectAppErrors` passes; the same provocation outside
  it fails; an UNMATCHED error inside the scope still fails; a scope that closes without
  matching anything fails.
- The suite is green at `--jobs 4`, either because nothing else throws or because every
  remaining error carries a named expectation with its reason written where it is
  installed.
- Whatever the detector finds is FIXED here, with a regression that fails without the fix.

## Non-goals

- Rust panics and device-side failures — a different transport and a different plan.
- Release-mode error behaviour. The sim runs debug; the red widget is a debug affordance.
