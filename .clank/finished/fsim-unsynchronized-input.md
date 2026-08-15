# fsim-unsynchronized-input — find why a driver command blocks for 20s, then fix that

## What this plan got wrong first

The previous draft asserted that `driver.tap` blocks until the frame scheduler goes
idle, and proposed running actions unsynchronized. That is already how the harness
works: `_rawDriverCall` wraps every call in `driver.runUnsynchronized`
(`sim_harness.dart`), and `tap`, `tapTooltip`, `enterText`, `waitFor`,
`waitForAbsent` and `getText` all route through it. So frame synchronization cannot
be the mechanism, and the proposed fix was work already done. The hypothesis came
from a triage note that was never checked against the harness — this plan does not
repeat that.

## Problem

`./fsim test --jobs 4` fails a small number of tests while every test passes solo,
and WHICH ones rotates between runs: erase_device and backup_restore in the run that
prompted this, psbt_sign, regtest_receive and regtest_send reported in others. The
shared symptom is `Timeout while executing <action>` after the 20s command timeout,
from a call that is already unsynchronized.

Two things are known and must not be conflated:

- **erase_device** hit this with a MODAL device-list sheet open over the wallet
  toolbar. Its screenshot showed the barrier, and dismissing the sheet fixed it.
  That navigation step is evidence-backed and stays.
- **backup_restore** failed differently — `tap("Close")` resolving to two
  hit-testable widgets — which is a targeting defect, not a timeout, and belongs to
  fsim-deterministic-targets.

What is NOT known is which phase of a driver command consumes the 20s: the finder
waiting for a hit-testable match, the command transport, the app's main isolate being
busy, or something else. Worse, as the model below shows, the harness currently
cannot tell you — its own timeout structure discards the answer. Every candidate fix
depends on it, so the plan produces it before proposing one.

## Model

A driver command is not one deadline, it is two nested ones of equal size, plus
three phases the outer one hides.

`_rawDriverCall` applies `Future.timeout(_cmdTimeout)` to the whole
`driver.runUnsynchronized(call)` future — which is `SetFrameSync(false)`, then the
action, then `SetFrameSync(true)` in a `finally`. The action itself already carries
the SAME `_cmdTimeout` (e.g. `driver.tap(finder, timeout: _cmdTimeout)`). The outer
deadline starts earlier and covers more, so it wins the race, and the inner error —
the one that would say which phase failed — is discarded in favour of a generic
outer timeout.

`Future.timeout` does not cancel its source, and neither does the app-side command
timeout. So after an outer timeout the operation is still running, with two
consequences worse than losing a message:

- diagnosis probes the app WHILE the original command is in flight, so what it
  reports describes a contended app rather than the failure;
- the abandoned future eventually runs its `finally` and re-enables frame sync,
  possibly during a LATER command on the SAME AppSession — which then synchronizes
  while its caller believes it does not. That poisons commands after the first
  timeout WITHIN one test process; it says nothing about which independent test
  session times out first under parallel load, and must not be stretched to.

So phase attribution is not merely instrumentation: the deadlines must be arranged
so the informative result survives, and an abandoned operation must not be left to
interfere with what runs next.

## Milestone 1 — split the action phase, then observe a real timeout

Preserving the inner error separates the action from the SetFrameSync calls around
it, and no further: inside FlutterDriver a `tap` waits for `finder.hitTestable` and
then calls `prober.tap` within ONE command, and the extension reports either
timeout as the same `Timeout while executing tap`. Milestone 2 cannot choose
between a finder-readiness fix and a budget fix on that. So the action phase itself
has to be split, by observation the harness can actually make:

- **Preflight the target.** Before dispatching, resolve the finder WITHOUT
  hit-testability on a short budget. Matching-but-never-actionable (the erase_device
  barrier) then reads differently from never-matching, which is the distinction the
  current message collapses.
- **Mark dispatch and response.** Timestamp the command leaving the harness and its
  reply arriving, so an app that never answers is distinguishable from one that
  answers late — transport and isolate delay versus execution.
- Where the driver API cannot see inside, use the app side: the sim app already
  serves `semantics-snapshot` over its own channel, and a diagnostic that reports
  hit-testability for a label is a committable equivalent.
- **Deterministic tests, one per classified phase** — a label that never exists, a
  labelled control behind a modal barrier, and a busy/unresponsive isolate — each
  forcing its own classification. Attribution that only appears under a flake is not
  attribution.
- Then reproduce a real timeout under load with artifacts retained, and report which
  phase it was. If reproduction proves unreliable, say so and pin what IS
  established rather than inventing a mechanism.

## Milestone 2 — the fix that Milestone 1's evidence points at

Deliberately unspecified. Candidate shapes, to be chosen by evidence:

- if it is finder-phase: the harness should wait for an ACTIONABLE target (and say
  so on timeout), rather than a matching one;
- if it is transport or isolate: the timeout budget or the beat-charged deadline
  (`SilentClock`) is the lever, not the finder;
- if it is app-side contention under `--jobs N`: the runner's parallelism defaults
  are the lever.

Whichever it is, acceptance is the flake rate: the suite green three consecutive
runs at the failing jobs level, plus a regression that fails without the fix.

## Non-goals

- Removing erase_device's sheet dismissal. It has direct evidence behind it.
- The ambiguous-finder defect (fsim-deterministic-targets).
- Reducing app animation. Nothing here has shown animation to be the cause.
