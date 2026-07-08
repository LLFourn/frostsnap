# keygen-save-settle-delay

Keygen currently lets the user reach the unplug prompt too quickly. After the final security-code
confirmation, the app calls `coord.finalizeKeygen(...)`, receives the `AccessStructureRef`, and
immediately pops the wallet-create flow into the "Wallet created! / Unplug devices to continue" state.
That presents a user instruction to unplug at the exact moment the finalize signal has only just been
sent down through the coordinator/Rust path.

Goal: after the user accepts the final keygen check, signal the coordinator by running
`coord.finalizeKeygen(...)`, keep the user in a visibly-busy "saving" state for 1 second after the call
succeeds, and only then transition to the existing unplug flow. The delay is an intentional product
guardrail: the user should see "saving to devices" instead of immediately seeing an instruction to
unplug.

## Tasks

### Task 1 — Add a post-finalize saving state in wallet creation
- Update `frostsnapp/lib/wallet_create.dart` around `_beginThresholdKeygen`.
- Once the final check is accepted, replace the final-check actions with a busy/disabled state before
  or while calling `coord.finalizeKeygen(...)`.
- Preserve the ordering: call `coord.finalizeKeygen(...)` first so the coordinator/Rust finalize
  signal is sent; after it returns successfully, wait for `const Duration(seconds: 1)` before
  `Navigator.pop(context, asRef)`.
- During this saving window:
  - show a spinner or equivalent progress affordance;
  - expose an accessible semantic label such as `Saving wallet to devices`;
  - disable "No", "Yes", back, and repeat-finalize paths.
- Preserve existing failure behavior: if `finalizeKeygen` throws, clear keygen state and show
  `Failed to finalize keygen: ...`; do not leave the dialog/page permanently disabled.

### Task 2 — Commit a sim regression for the user-visible guardrail
- Add or update a `test_driver` flow that reaches a normal keygen final-check dialog, taps `Yes`, and
  asserts `Saving wallet to devices` appears before the unplug prompt.
- The test should fail against the old immediate-pop behavior. Suggested shape:
  - drive a normal 1-of-1 keygen to the final-check dialog;
  - tap `Yes`;
  - assert `Saving wallet to devices` appears;
  - assert `Unplug devices to continue` is not immediately reachable while saving is shown;
  - after saving clears, wait for `Unplug devices to continue`, then unplug.
- Keep the assertion focused on the committed UX behavior, not on manual smoke-test confirmation.

### Task 3 — Keep the scope narrow
- Do not add a broad delay to every navigation or all Rust calls. The delay belongs only to successful
  keygen finalization, after the finalize signal has been sent through `coord.finalizeKeygen(...)`.
- Do not redesign the keygen protocol or add a new device persistence acknowledgement path in this
  plan.
- Keep the copy short and user-facing: communicate that the wallet is being saved to devices and that
  unplugging is not yet safe.

## Non-goals
- Changing keygen cryptographic protocol semantics, device storage format, or wallet backup flows.
- Adding coordinator/device durable-save acknowledgement plumbing. This plan is the requested
  user-facing guardrail around the existing finalize path.
- Changing the later "Unplug devices to continue" dialog except that it must not become reachable until
  the 1 second saving window completes.
