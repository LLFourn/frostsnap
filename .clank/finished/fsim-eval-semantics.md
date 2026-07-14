# fsim-eval-semantics
# fsim eval semantics

## Goal

Expose the current app semantics surface through the existing `fsim eval` API so a human or test can ask "what can I see or drive right now?" without adding a parallel CLI command path. The inspection surface must be tied to the same semantic labels that `tap`, `waitFor`, `exists`, and text entry already drive.

The first pass should be small and useful:

```sh
./fsim eval 'await session.semantics().pretty()'
./fsim eval 'await session.semantics().labels()'
./fsim eval 'await session.semantics().grep("Generate keys")'
./fsim eval 'await session.semantics().json()'
```

`session.semantics()` should return a small inspector object synchronously; each accessor fetches a fresh snapshot asynchronously. That keeps the common `await session.semantics().pretty()` shape ergonomic and makes every call describe the current app state.

## Scope

- Add a `session.semantics()` helper object to the sim harness.
- Implement the data collection through the same live app/driver-data path the harness already uses, so it works from `fsim eval` and from Dart test code.
- Guaranteed minimum surface: every semantic label that is targetable by the existing `find.bySemanticsLabel`-based helpers in the current app state.
- Best-effort surface: values, hints, flags/actions, role-ish booleans such as button/text field/slider, and screen bounds when Flutter exposes them cleanly. These enrich debugging, but callers should not need them for the first-pass contract.
- Add a `pretty()` formatter that prints a compact tree or indented list meant for humans reading terminal output.
- Add `labels()` and `grep(pattern)` helpers for the common "what text can I target?" workflow.
- Keep `json()` stable enough for scripts/tests to inspect without parsing pretty output.
- Update `test_driver/COMMANDS.md` and `fsim eval --help` with the new examples.

## Non-goals

- Do not add top-level `fsim tree` or `fsim grep` commands; keep the surface inside `fsim eval`.
- Do not introduce generic coordinate dragging.
- Do not solve threshold selection yet. For this plan, "threshold semantics" means whatever the current keygen threshold selector already exposes to Flutter accessibility; a later plan can add an explicit `Threshold` control/value surface and a drivable setter if needed.
- Do not expose a raw Flutter widget tree. This is about the semantic surface the harness can drive/assert against.

## Acceptance

- `labels()` and `grep(...)` report the same semantic-label surface that the existing `tap`, `waitFor`, `exists`, and text-entry helpers can resolve in the current app state. In a known keygen state, `grep("Generate keys")` is non-empty and the returned `Generate keys` label can be matched by `exists`/`waitFor`.
- Add one automated smoke check that reaches a known app state, fetches `session.semantics()`, and asserts expected keygen-screen labels are present. This should exercise the same API shape available from both `fsim eval` snippets and Dart test code.
- `./fsim eval 'await session.semantics().pretty()'` prints a human-readable snapshot containing the same labels shown by `labels()`.
- `json()` returns structured semantic data without requiring callers to parse terminal formatting.
- Existing `tap`, `waitFor`, `exists`, and text-entry helpers continue to use the same semantic labels they use today.
