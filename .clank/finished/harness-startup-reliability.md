# harness-startup-reliability
# The harness fails ~2 runs in 3 before a test reaches its own code

On ONE unchanged tree, `./fsim test psbt_sign --android --jobs 1` gave three different outcomes:

| run | outcome | where it died |
|---|---|---|
| 1 | FAIL | `Bad state: sim app semantics never became usable — find.bySemanticsLabel(…SIMULATOR\|Open simulator…) did not resolve within 60s`, in `AppSession._launchApp` (`sim_harness.dart:1108`) |
| 2 | PASS | ran to completion — QR scanned, 2-of-3 signed, broadcast, amount confirmed node-side |
| 3 | FAIL | `requestData("recognized-device-ids") failed: TimeoutException after 0:00:20`, in `AppSession._requestData` (`sim_harness.dart:1205`) via `_awaitChainRecognized` ← `AppDevice.setConnected` ← `createWallet` |

**Not one failure reached the scenario's own logic.** Both died in harness plumbing — app launch and
device-chain recognition. So this is not about `psbt_sign`; that driver is incidental, and any test would
do as the reproducer.

## Why this matters beyond annoyance

The fork's `master` publication gate is supposed to rest on a green run. **It cannot rest on a suite that
fails two runs in three for reasons unrelated to what is being tested.** And the obvious mitigation is the
wrong one: retrying until green converts "intermittent" into "pass", which is precisely the information a
gate exists to surface. `sim-e2e-startup-flake-retry` and `fsim-opt-in-retries` make the SUITE resilient;
they do not make a single run trustworthy, and this rate is far worse than that plan's record implies.

## What the evidence already says — don't re-derive it

- **Run 3 positively exonerates the app.** The captured log
  (`frostsnapp/build/sim-failures/psbt_sign/error.txt`) shows all three devices logging
  `Registered device device_id=…` and a `KeyGen` being queued. The three `dart sent cancel` lines after it
  are the driver tearing down *after its own read timed out*. The app was healthy; the harness's
  `requestData` round-trip was not.
- **`Lost connection to device` is NOT a failure signal.** It appears in the PASSING run too, at teardown.
  I wasted a diagnosis cycle treating it as diagnostic — the real markers are the two quoted above.
- **Load is a plausible aggravator, unproven.** Run 3 took 271.6s against the warm pass's 140.3s, inside a
  723.5s invocation that included a full rebuild. A fixed 20s `requestData` timeout may simply be too tight
  under contention. Worth checking whether these waits are fixed deadlines that should scale, or should
  wait on a readiness signal instead of a clock.
- **`fsim` exits 0 on a FAILED test.** Its exit code is not a pass signal — only the `test result:` line
  is. Anything scripted around fsim that checks `$?` silently treats failure as success. Worth fixing on
  its own.

## What to do

Find out why the two startup/handshake waits are unreliable and make them deterministic — a readiness
signal beats a longer timeout. If some waits genuinely cannot be made deterministic, say so explicitly and
say what the honest confidence level of a single green run then is, because the gate needs to know.

## What NOT to do

- **Do not just raise the timeouts** without establishing what the wait is actually racing. A longer clock
  hides the race at a higher load level rather than removing it.
- **Do not make retries the answer.** See above: that is the one mitigation that destroys the signal a
  publication gate needs.

## Environment note

Runs were on Android, `--jobs 1`. Both Flutter 3.41.7 and the pinned 3.38.5 (`frostsnapp/.fvmrc`) produced
failures, so this is not version-specific. Note that local runs had been using 3.41.7, off the pin; the pin
is now available at `~/flutter-versions/3.38.5/flutter/bin` and is what CI actually uses, so prefer it —
`PATH=~/flutter-versions/3.38.5/flutter/bin:$PATH ./fsim …`.

## Constraints

- **No WHAT comments.** No comment that restates the code, paraphrases a function's own name, narrates a
  sequence, or carries PR/changelog meta. Only WHY, and only when the why isn't obvious. Test: delete the
  comment — if the code still says everything it said, leave it deleted.
- **Prefer no test to a mocked one.** A seam test that fakes the readiness signal proves nothing about the
  race it is meant to close.
