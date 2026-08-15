# fsim-label-diagnostics

An unmatched semantic label must produce a DESCRIPTIVE error naming what WAS on stage — never a 20s
hang that dies as "Lost connection to device". Driver-call failures also say WHICH of three very
different things happened: label never matched, the app process died, or the VM-service connection
really dropped.

## Why

`tap`/`tapUntil`/`waitFor`/`exists` with a String do an EXACT label match (`find.bySemanticsLabel`).
The home CTA card merges title+subtitle into one label, so the natural
`tapUntil('Create a multi-sig wallet', …)` matches NOTHING — and the failure surfaces as "tap message
is taking a long time" → "Lost connection to device" → a generic TimeoutException. The PR-505
recording effort lost hours to this: the same error string covered (a) a label that never matched,
(b) an OOM force-stop of the app, and (c) a real driver drop. The harness already holds everything
needed to disambiguate: the semantics snapshot (on-stage labels), the app process exit future, and
the app log tail — the tapTooltip resolver already sets the diagnostic precedent (zero matches →
list what IS available).

String matching stays EXACT — silently switching to substring would change what every existing test
targets and invite ambiguity bugs. The fix is diagnostics, not new matching semantics.

## Scope — `frostsnapp/test_driver/sim_harness.dart` (+ a pure helper module)

### Label-miss diagnostics
- Pure helper (new `test_driver/label_diagnostics.dart`): given the attempted Pattern and the
  on-stage labels, produce the error text — exact-String miss with substring hits → "no EXACT label
  match for 'X'; labels CONTAINING it: …; use RegExp for substring matching"; no hits at all → the
  on-stage label listing (bounded, e.g. first ~20, with a "+N more" tail); RegExp miss → same
  listing. Unit-tested.
### ONE failure classifier at the central wrapper — a reachable snapshot alone proves nothing
A snapshot that resolves does NOT prove a label miss: the label may still be on stage while the
action failed for a driver reason, or the tap may have SUCCEEDED and removed its own target before
the failed response was observed. Every driver-call failure goes through one classifier (pure
decision function in the module; `_driverCall` gains an optional finder-Pattern context), producing
exactly one of:
1. **App exited** — the CACHED app exit status is set → "the app process exited (code N) during
   <verb> — recent app log: <bounded tail>" (the harness already buffers the log). `appExitCode` is
   only a Future today (`sim_harness.dart:602`); the session RECORDS its completion into an
   `int? _appExitStatus` field at construction (`.then`), and the classifier reads the cache — it
   never awaits.
2. **Label miss** — snapshot reachable AND a finder context was given AND the Pattern has ZERO
   current matches → the label-miss diagnostic (above). The misleading raw
   DriverError/TimeoutException text is NOT appended — a confidently classified miss must not say
   "Lost connection".
3. **Action/driver failure** — snapshot reachable AND (no finder context, OR the Pattern DOES match
   on stage) → PRESERVE the original error (lightly prefixed with the classification); never a
   false "no label".
4. **Connection failure** — the snapshot request itself fails → re-check the cached exit status
   FIRST (a just-completed force-stop wins as case 1), else "driver/VM-service unreachable" with
   the original error preserved.

### The probe transport is RAW — the classifier must not diagnose itself
The snapshot probe is fetched via `_requestData` today (`sim_harness.dart:99-108`), and
`_requestData` itself participates in classification — routed naively, a failed probe would
recursively classify (fetch another snapshot, fail again, …). The classifier uses a RAW
requestData primitive (a direct `driver.requestData` call with NO diagnosis); the normal
public/internal request path layers OVER the diagnosing wrapper. Unit seam: one failed snapshot
probe produces exactly one connection classification (or the cached-exit recheck) — no recursion.

### Which verbs carry finder context — the label applies to the FINDER phase only
- `tap` / `waitFor` / `getText`: their Pattern is the context for the whole call (case 3 protects
  the matched-but-action-failed path). NOT `getTextByKey`: a ValueKey is absent from the semantics
  snapshot, so key-as-Pattern would ALWAYS manufacture a label miss listing unrelated labels — it
  stays a no-label-context action/driver call.
- `enterText`: context ONLY on its focus-tap step; the IME/typing phase runs with NO finder context
  (a typing failure must never be rewritten as a focus-label miss).
- `tapUntil`: each attempt's tap carries the tapped label; the EXHAUSTED outcome diagnoses the
  missing `expect` Pattern (zero matches → its listing), not the successfully tapped label.
- `waitForAbsent`, `_requestData`, and every other non-finder driver call: NO label context — they
  participate in cases 1/3/4 only. `exists` keeps returning false (a predicate) — no change.
- The verbs' wait budgets are load-bearing (they legitimately wait for widgets to APPEAR) — timing
  is unchanged; the failure is what gets fixed.

### Tests
- Unit (`frostsnapp/test/label_diagnostics_test.dart`): the formatter — exact miss with substring
  hits (suggests RegExp, lists hits); no hits (bounded listing + "+N more"); RegExp miss; empty
  stage. AND the pure classifier decision — cached-exit wins; snapshot-reachable + zero matches →
  miss; snapshot-reachable + matching Pattern → action failure preserving the original; no finder
  context → never a miss; snapshot-unreachable → exit recheck then connection; a FAILED snapshot
  probe classifies exactly once (no recursive probing — the probe seam is injectable).
- e2e (host, cheap, COMMITTED in the suite — pure formatter tests cannot prove tap/waitFor actually
  route through the classifier): a scenario that CATCHES the intentional failures and asserts —
  `tap('Create a multi-sig wallet')` error names the merged CTA label and suggests RegExp;
  `waitFor('nonexistent-xyz')` error lists on-stage labels; neither contains "Lost connection". The
  suite stays green (the failures are caught and asserted).

## Acceptance
- `fsim eval "await session.tap('Create a multi-sig wallet')"` fails with an error that LISTS the
  merged CTA label and suggests RegExp — no "Lost connection", no bare TimeoutException.
- `waitFor('nonexistent')` timeout error lists the current on-stage labels.
- Killing the app mid-drive (e.g. `adb shell am force-stop com.frostsnap` during a waitFor on an
  android session) yields the app-died error with the log tail, not a label/connection error.
- A failure while the label DOES match on stage preserves the original driver error
  (classifier-unit-covered) — never reported as a label miss.
- The committed negative-path scenario runs green in the host suite.
- Unit tests green; `dart analyze` clean; host suite green (no timing changes).
