# fsim-opt-in-retries

Replace the automatic transient-flake retry in `fsim test` with an opt-in `--retries N` flag (default 0).
By default a failure is a failure — one attempt, exit 1. CI opts into retries explicitly.

## Why

The batch runner classifies each failure as a "transient flake" vs a "real failure" by string-matching the
captured log (`isTransientFlake` / `_realFailureSignatures`) and silently re-runs the "flaky" ones up to 3×
(`_maxTestAttempts`). That heuristic is fragile — it keys off `Failed to fulfill SetFrameSync` /
`Lost connection to device` appearing WITHOUT `Bad state:` / `Expected:` / … — and, worse, it hides
instability: a test that only passes on attempt 2 still reports green with no failure surfaced to the exit
code. Make the default honest, and push the retry decision to an explicit flag CI can set.

## Scope — `frostsnapp/test_driver/fsim.dart` + `frostsnapp/test/` (one commit, tree green)

### Runner — opt-in retries, drop the flake heuristic
- DELETE `isTransientFlake` (`fsim.dart:1028`) and `_realFailureSignatures` (`:1016`) entirely — the whole
  classification goes.
- DELETE the `_maxTestAttempts = 3` const (`:1009`).
- ADD a `--retries N` option to the `fsim test` arg loop (`:879-899`), before the
  `if (a.startsWith('--')) continue;` catch-all. Default 0; reject N < 0 with a clear message + `exit(2)`.
- Call site (`:968-980`): `runWithRetry((_) => _runOneTest(...), (res) => res.failed, maxAttempts: 1 + retries)`
  — retry ANY failed test up to N extra times (no flake filter).
- `runWithRetry`: change the `maxAttempts` default from `_maxTestAttempts` to `1` (one attempt = no retries);
  keep the pure helper otherwise unchanged.
- `_reportRetries` (`:1051`): drop the "transient startup flake" wording → e.g. "recovered after N retries" /
  "FAILED after N attempts". Only ever prints when `--retries > 0`.
- Summary (`:809`): `($retried retried a transient flake)` → `($retried retried)`. Doc comment (`:725`):
  "Transient-flake retries" → "Retries". KEEP the `_TestResult.retries` field + JUnit `retries=` attribute.
- Help text (`:110-119`): add `[--retries N]` to the `fsim test` usage line + a one-line description
  (default 0; each retry re-runs a failed test from a fresh launch).

### Tests
- Rename `test/flake_retry_test.dart` → `test/retry_test.dart`; rewrite the header (no flake-plan reference).
- DELETE the entire `isTransientFlake` group (function is gone) and drop it from the import.
- Keep the `runWithRetry` group, passing explicit `maxAttempts`; ADD a case: `maxAttempts: 1` runs the attempt
  once and does NOT retry a failing result (retries 0, calls 1).

Land runner + tests in ONE commit — removing `isTransientFlake` breaks the old test's import, so the tree must
not be split across an intermediate red state.

## Acceptance
- `fsim test <name>` on a failing scenario → ONE attempt, exit 1, no retry line.
- `fsim test --retries 2 <name>` → up to 3 attempts; green (with a reported retry count) if any attempt passes,
  else exit 1.
- `grep -rn "isTransientFlake\|_realFailureSignatures\|transient flake" test_driver test` → no hits.
- `flutter test test/retry_test.dart` green; `dart analyze test_driver/fsim.dart` clean.
