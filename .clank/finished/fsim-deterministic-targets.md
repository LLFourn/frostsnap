# fsim-deterministic-targets — a tap must name exactly one control

## Problem

In the same parallel run that produced the timeout flakes, backup_restore failed
differently:

```
tap("Close") failed … The finder "Found 2 widgets with widget with semantic label
"Close" (considering only hit-testable widgets …)" ambiguously found multiple
matching widgets. The "tap()" method needs a single target.
```

Two sheets were momentarily stacked — one closing while the next opened — so for a
few frames the app really did have two hit-testable "Close" buttons. The test asked
for "the Close button" at a moment when that phrase did not identify anything.

Note what the message says: **two widgets matching the SAME label**. Not two different
labels that a loose pattern both matched. Any fix that only disambiguates between
distinct strings does not address this bug.

This is not the timeout mechanism (fsim-unsynchronized-input, now landed) and is not
fixed by it. It may get MORE frequent now: that plan restored genuinely unsynchronized
action for the nested case, so taps land mid-transition rather than stalling — and
mid-transition is exactly when two transient copies of a control coexist.

## Model

`tap(label)` is a promise that the label names one control. The harness already honours
that promise in one place: `tapTooltip` resolves its pattern against the on-stage
tooltips (`tooltip_resolve.dart`) and reports zero-or-many with the candidates listed,
so the failure tells you what to write instead. `tap` hands the same kind of pattern to
a raw finder, so the same situation produces a driver-internal message about widget
counts — a failure about Flutter's internals rather than about the test's intent.

Ambiguity is also not always the test's fault: sometimes two controls genuinely coexist
for a few frames, and the right answer is to wait for one rather than to name it better.
The harness should make that distinction available rather than forcing every call site
to guess.

### Which APIs promise uniqueness — and which must NOT

These are two different contracts and the previous draft ran them together. Making
observations require uniqueness would break ordinary waiting: a wait exists precisely to
watch a screen in flux, and "two matches for a moment" is a normal state to pass through,
not a failure.

**Singular actions — MUST identify exactly one hit-testable target:**
`tap`, the tap step of `tapUntil`, the focus tap of `enterText`, `tapTooltip` (already).

**Existential observations — MUST keep answering "does any match exist?" and must NOT
gain a uniqueness requirement:** `waitFor`, `waitForAbsent`, `exists`, `appears`.

**The explicit transient case** gets its own named operation rather than changing either
contract: `tapWhenUnique(label, {timeout})`. It must obey the same action-decides rule as
everything else below — polling a count and then tapping would put the count-change race
into the ONE API whose entire purpose is to handle a changing count.

So its decision boundary is the action itself: attempt the singular action, and retry
ONLY on an outcome known to have occurred before any mutation. The driver's ambiguity
failure is such an outcome — it is raised while resolving the finder, before `prober.tap`
— so retrying it cannot double-fire. A TIMEOUT is not: per the quarantine model, a
timed-out action may still land, so it must fail rather than retry. Terminate on the
first successful action, which makes exactly-once structural rather than asserted. An
app-side atomic count-and-tap is an acceptable equivalent.

A count probe may enrich the failure message; it must never authorize the tap. Failing
within the timeout reports the counts observed, so "it never settled" is distinguishable
from "it was always ambiguous".

## Milestone 1 — ambiguity is a harness-level answer, not a driver-internal error

Two properties the resolution MUST have, both of which the obvious implementation lacks:

- **Multiplicity-preserving.** `semantics().labels()` deduplicates (`sim_harness.dart`,
  `seen.add(label)`), so two identical "Close" buttons collapse to ONE: a resolver built
  on that convenience API sees a single match, proceeds, and the driver still fails with
  its internal message — the observed bug passes straight through the fix. The RAW
  snapshot does keep every node, marking repeats `labelFirstSeen: false` (`sim_app.dart`),
  so multiplicity is available there — but it must be counted deliberately, and the
  deduplicating API must not be the one built on.
- **Action-faithful.** The snapshot walks `debugVisitOnstageChildren` with no
  hit-testability filter, while `driver.tap` resolves `.hitTestable()`. The two candidate
  sets are not the same, so counting one and acting on the other is not a fix.

Resolve-then-act is also a two-step: the count can change between resolving and tapping,
which is the very condition being diagnosed. Prefer a design where the ACTION decides —
attempt it, and translate the driver's ambiguity failure into the harness's vocabulary,
asking the app for hit-testable candidates only to build the message. That mirrors the
pattern already used for timeouts (act, then probe for the explanation), and has no
decision race because there is no separate decision. An equivalent design is acceptable
if it demonstrably has both properties above.

- Singular actions report zero / many with candidates listed, in the test's own
  vocabulary, including the count for each repeated label.
- App-side support for a HIT-TESTABLE, multiplicity-preserving candidate count per label
  (the existing `hit-test:` verb reports what a tap lands on, not how many match).
- `tapWhenUnique` as specified above.
- Unit coverage for the resolution rules (zero / one / many / settle), dependency-free in
  the style of `driver_phase.dart` and `tooltip_resolve.dart`.

## Milestone 2 — fix backup_restore

- Decide by OBSERVATION, not by guessing here: capture the failing moment and determine
  whether the two "Close" buttons are a naming problem (point the step at an unambiguous
  target) or a genuine transient overlap (use `tapWhenUnique`). The retained artifact from
  the run that prompted this plan is the starting evidence.
- Verify the way the flake was found: solo, then under `--jobs 4`.

## Acceptance

- A regression with TWO IDENTICAL hit-testable "Close" candidates — the observed shape,
  not a regex matching two distinct strings — fails with the harness diagnostic listing
  candidates and counts, never FlutterDriver's widget-count message.
- A settle-path test that pins the DECISION POLICY, not just a candidate vanishing: with
  two identical candidates present, `tapWhenUnique` must retry the action itself (never
  tap on the strength of a count read), and once one candidate goes away it must act
  EXACTLY once — assert the app saw a single activation, so a retry loop that fires on
  every attempt fails the test. A timed-out attempt must NOT be retried.
- An existential observation (`waitFor` / `exists`) against a label with two matches
  still succeeds — the contract split is pinned, not just described.
- backup_restore green solo and under `--jobs 4`, three consecutive runs.

## Non-goals

- The frame-scheduler timeout class — fsim-unsynchronized-input, landed.
- Rewriting every existing test's finders. Only what is demonstrably ambiguous.
