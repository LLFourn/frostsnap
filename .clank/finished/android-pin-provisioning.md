# android-pin-provisioning

The android emulator provisioning (`_provisionEmulator`, `frostsnapp/test_driver/simctl.dart`) sets a
secure lock PIN (`0000`) and unlocks the keyguard before each app launch. Two problems:

1. **The unlock leaks keystrokes.** `wm dismiss-keyguard` then `input text 0000` types the PIN
   UNCONDITIONALLY. When the device isn't actually on the PIN bouncer (fresh emulator / already
   dismissed), the `0000` lands on the launcher's Google search widget → a stray web search. The
   "entering the PIN if one is already set (harmless otherwise)" comment is wrong.
2. **It may be unnecessary.** The rationale ("Frostsnap requires a secure lock, as it keystores
   secrets behind device authentication") is an unverified COMMENT; empirically the devices run
   unlocked and the suite — including `keygen` + `regtest_send`, which exercise the keystore — passes.
   Decide whether the secure lock is actually required before choosing fix-vs-delete.

## Tasks

### Task 1 — Determine whether the secure lock is required
- Grep the app for the keystore dependency (`SecureKeyManager` / Android keystore key params): do the
  keys set `setUserAuthenticationRequired(true)` (which REQUIRES a secure lock) or not? Ground the
  comment's claim in actual code.
- Empirically: provision an emulator WITHOUT `set-pin` (no secure lock) and run `keygen` +
  `regtest_send` on it. If they pass, secret storage works without a secure lock.
- Conclude: required, or not — and make the provisioning comment match.

### Task 2 — Fix or delete based on the finding
- **If NOT required:** remove the PIN/unlock block (`dismiss-keyguard` + `input text 0000` +
  `KEYCODE_ENTER` + `set-pin`). Keep `stayon`/`WAKEUP` (the app ANRs without a focused window) and the
  nav-bar config. A fresh emulator's swipe keyguard is cleared by `dismiss-keyguard` alone.
- **If required:** keep `set-pin` (the secure lock the keystore needs) but make the unlock leak-proof —
  only `input text 0000` when the device is actually locked (`dumpsys trust` → `deviceLocked=1`), so the
  PIN only ever fills the bouncer, never the launcher.

## Acceptance
- No phantom Google search during provisioning (provision a fresh pool emulator and confirm the
  launcher/search never receives the keystrokes).
- `keygen` + `regtest_send` still pass on android (secret storage works in whichever config we land on).
- The provisioning comment reflects reality — no false "requires a secure lock" claim if it's deleted.

## Non-goals
- Changing the app's real keystore/lock behaviour — this is sim provisioning only.
- The nav-bar / `stayon` provisioning (unaffected).
