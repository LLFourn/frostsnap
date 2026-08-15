# fsim-sim-delete-secure-key
# fsim-sim-delete-secure-key — delete the app's secure key from a sim eval + drop the dead clearKey

Let a sim session DELETE the app's main secure key (the `AndroidKeyStore` HMAC key — StrongBox on real
hardware, TEE on the emulator) via `fsim eval`, so tests can exercise the otherwise-unreproducible "hardware
key is gone → regenerate / recover" path. And remove the dead `clearKey` no-op while we're in this surface.

Grounding (already on disk): the native delete EXISTS and is fully wired — `SecureKeyManager.deleteKey()`
(`keyStore.deleteEntry(KEY_ALIAS)`) ← MethodChannel `"deleteKey"` ← `AndroidSecureKeyProvider.deleteKey()`
(`_channel.invokeMethod('deleteKey')`), and the platform-agnostic `SecureKeyProvider.deleteKey()` is declared +
implemented for android AND desktop. So the ONLY missing piece is the sim eval surface. `clearKey` is a pure
no-op (`// No-op since we don't cache authentication`) with ZERO callers (grep: only its own
Kotlin/interface/2-impl definitions).

## Task 1 — remove the dead `clearKey` no-op
Net-negative deletion, zero behaviour change (nothing calls it):
- Kotlin `SecureKeyManager.kt`: the `clearKey(result)` method and its `"clearKey" -> clearKey(result)` dispatch
  case.
- Dart `secure_key_provider.dart`: the `clearKey()` interface method and BOTH impls (`AndroidSecureKeyProvider`
  `invokeMethod('clearKey')` + `DesktopSecureKeyProvider`).
- Re-grep to confirm no caller anywhere before deleting; if one turns up that INTENDED real clearing, flag it
  (a latent no-op bug) rather than silently dropping.
- **Acceptance:** `clearKey` gone from Kotlin + Dart; `flutter analyze` / `dart analyze` clean; the app still
  builds + `./fsim test keygen` green (the key path still works).

## Task 2 — `session.deleteSecureKey()` (+ a verification handle) for the eval console
- Add a sim driver-extension endpoint in `test_driver/sim_app.dart`'s `_driverData` handler (the `app-screenshot`
  pattern), e.g. `'delete-secure-key'`, that calls `SecureKeyProvider.instance.deleteKey()`.
- Add harness `AppSession.deleteSecureKey()` → `_requestData('delete-secure-key')` (mirrors `screenshot()`), so
  `fsim eval "await session.deleteSecureKey()"` deletes the key.
- Add a VERIFICATION handle so the acceptance can PROVE the delete really happened (the `clearKey`-was-a-secret-
  no-op lesson): `session.secureKeyExists()` → a `'secure-key-exists'` endpoint returning
  `keyStore.containsAlias(KEY_ALIAS)` (expose a minimal read-only `hasKey`/`containsAlias` via the existing
  SecureKey channel if one isn't already there). Genuinely useful for tests to assert key state.
- Docs: `test_driver/COMMANDS.md` rows for both (drift-guard test).
- **Acceptance (validated on the android emulator on this box):** `fsim up --android` → ensure a key exists
  (`session.secureKeyExists()` → true, generating it first if needed) → `fsim eval "await
  session.deleteSecureKey()"` completes without error → `session.secureKeyExists()` → **false** (proving a REAL
  delete, not a no-op). On a HOST session, define + verify the intended behaviour (delete the desktop provider's
  key, or a clear android-scoped error). analyze + format clean; drift-guard green.

## Notes
- DESTRUCTIVE by design: deleting the key means the app's data encrypted under it can no longer be decrypted —
  on the next cold start the app hits its key-gone / recovery path. That IS the scenario this enables; it is
  sim-only (the driver extension is enabled only in sim builds — never reachable in production).
- Android-focused (the StrongBox/AndroidKeyStore key). The emulator has no StrongBox hardware, so its key is
  TEE-backed — but `deleteEntry(KEY_ALIAS)` is identical, so the app-level "key gone" behaviour is exactly what
  gets tested. Desktop uses `DesktopSecureKeyProvider` (a different store), handled per the acceptance.
- No new native DELETE code needed (it exists); Task 2 is sim plumbing + at most a tiny read-only existence
  check.
