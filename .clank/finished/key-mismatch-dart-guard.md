# key-mismatch-dart-guard

REDO the Android key-mismatch handling as a **compact, brittle Dart-side guard, with NO
`frostsnap_core` changes.** This deliberately replaces the current typed-error-in-core solution —
drop the old work and start over.

## Why (read this first)

The current solution (the finished `[android-keystore-fallback]` + `[key-unavailable-recovery-routing]`
plans, = PR #4) adds **typed key-mismatch errors inside `frostsnap_core`** and threads them through
the FRB API — ~30 files, deep: `frostsnap_core/src/{coordinator,restoration,lib}.rs` + 5
`frostsnap_core/tests/*.rs`, plus `frostsnapp/rust/src/api/{recovery,signing,backup_run,mod}.rs`.
That is far too invasive for a **temporary** concern: the upcoming **"lock wallet"** feature moves to
a model that doesn't care about the `frostsnap_core` decryption key at all, so this whole
key-mismatch error path goes away. A brittle Dart-only guard is the better trade for now.

## Drop the current work

- Base the redo on **`origin/master`** (the consolidated-sim master, `955e3745`). Effectively drop
  everything the two keystore plans added.
- **Hard constraint:** `git diff origin/master -- frostsnap_core/` must be **EMPTY** (src AND
  `frostsnap_core/tests`). No core changes, no core typed-error changes. A **minimal** probe
  wrapper in `frostsnapp/rust` that calls an EXISTING core method (e.g. `root_shared_key`) IS
  allowed — that's the intended place for the decrypt check.

## The redo — one compact guard

- Add a **single, SUPER-COMPACT Dart helper** — e.g. `checkEncryptionKey(...)` — that does a QUICK
  check of whether the app's encryption key can decrypt *this* wallet, and on failure shows the
  existing delete-and-recover dialog (`showWalletKeyMismatchDialog`, "Wallet needs recovery") and
  aborts the operation. Keep this routine tiny.
- Call the guard at the actual operation **call sites only** — sign tx (`wallet_send_controllers`,
  `wallet_tx_details`), sign message, show/check device backup (`device_action_backup*`), and
  recover-into-existing (`restoration/*`). A small, focused edit at each site.
- The check must use an **existing** decrypt-returning-nullable path already exposed to Dart (e.g. a
  `root_shared_key(encryptionKey)`-style call that returns null on the wrong key). Do NOT add core
  code for the probe. If a suitable binding doesn't already exist, a *minimal* FRB wrapper that calls
  an existing core method is acceptable — but **zero `frostsnap_core` edits**. Brittleness (a
  pre-check that can drift from the operation) is explicitly ACCEPTABLE here.
- The empty-key fallback in Kotlin `SecureKeyManager` is not a core change — keep it if it's still
  needed for new wallets on broken-keystore devices; your call.

## Keep

- The delete-and-recover dialog (`wallet_key_mismatch.dart`) and the no-lock-screen-vs-existing-wallet
  distinction can live on the Dart side — just drive them from the guard's quick check, not from core
  typed errors.
- The e2e tests (`key_pin_clear_recovery`, `key_delete_recovery`, `recover_lock_required`,
  `key_mismatch`) — keep them; make them pass under the Dart-guard approach.

## Deliverable

- **ONE commit** on top of `origin/master` (the PR should be a single commit). Force-push to update
  PR #4 (`android-keystore-fallback`).
- `git diff origin/master -- frostsnap_core/` empty (a minimal `frostsnapp/rust` probe wrapper is OK).
- `./fsim test key_pin_clear_recovery --android` (and the others) green; `just lint` clean
  (incl. `dart format`).
