# sim-6-keygen-widget-keys
# sim-6: stable Keys/Semantics on the keygen flow controls

## Goal
Give the keygen UI deterministic, replayable handles so the app half can be driven by Key (not
brittle pixel coordinates) in sim-7. Small, isolated, behavior-preserving.

## Core model (read first)
Flutter paints to a canvas and exposes no native a11y tree, so the only stable way to target a
control out-of-process is a `Key`/`Semantics`. Today the keygen flow has incidental route/list
keys but **none on the workflow controls** (AUTOMATION_RESEARCH Axis 5). Add them with one
documented naming scheme (e.g. `Key('keygen.<step>.<action>')`) so a script and a human read the
same handles.

## Tasks
Add stable `Key`/`ValueKey` (and `Semantics` label where a screen reader value helps) to each
control a 1-of-1 keygen tap-walk hits — anchors verified against the current tree (the implementer
pinpoints the exact widget):
1. Create-multisig entry — the `AddType.newWallet` action item ("Create a multi-sig wallet")
   `frostsnapp/lib/wallet_add.dart:49-53`; dialog opens at `:176` (`showWalletCreateDialog`).
2/3/6. **The step button is a SINGLE `FilledButton`** at `wallet_create.dart:1206` whose label +
   action change by `_step` (`nextText`: "Next" → "Continue…" → "Generate keys", `:470`/`:1215`/
   `:1221`). Key it **per step** (e.g. `ValueKey('keygen.next.${_step.name}')`) so sim-7 can both
   target it and assert which step it's on, rather than a single ambiguous key.
4. Per-device inline name field — the device-row `TextFormField` in the devices step (near the
   devices `FilledButton` `:813`).
5. ThresholdSelector — usage at `wallet_create.dart:856` (the widget already accepts `super.key`,
   `threshold_selector.dart:15`); key it at the use site.
7. Keygen confirm dialog "No"/"Yes" — `wallet_create.dart:970-976` (two `TextButton`s).
8. Keygen dialog "Cancel" — `wallet_create.dart:186` (`OutlinedButton`).

Record the key names in a short doc comment / constants file (e.g. a `keygen_keys.dart` or a const
block) so sim-7 imports the exact same handles.

## Acceptance
- Every control above has a stable, documented `Key`; `flutter analyze` clean; zero behavior
  change (keys/semantics only — no logic edits).

## Non-goals / deferred
No driver/test yet (sim-7). Signing/restoration controls out of scope (keygen path only).

## Depends on
sim-5 (the sim flow must exist to exercise these). Can be reviewed independently of sim-7.
