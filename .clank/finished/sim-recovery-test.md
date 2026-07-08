# sim-recovery-test
# sim-recovery-test — e2e wallet recovery from devices

## Goal

Add a driver e2e test that exercises **wallet recovery**: create a wallet, DELETE it from the app (the
coordinator loses the wallet, the DEVICES keep their key shares), then RECOVER it by plugging the devices in
sequentially and driving the app's recovery flow. Asserts the recovered wallet equals the original.

This covers a class we don't test today (only keygen + send/receive exist) and is the realistic
"lost/reinstalled the app, restore from my Frostsnap devices" scenario.

## Grounded context

- **Model on** `test_driver/keygen_2of3_drive.dart` — it creates a 2-of-3 wallet over a 3-device chain
  (bring up 4, drop 1) and finishes at wallet home. Recovery is the natural sequel: tear the wallet out,
  bring it back from the devices.
- **Recovery UI** lives in `lib/restoration.dart` (`WalletRecoveryFlow`, `RecoveryFlowWithDiscovery`,
  `continueWalletRecoveryFlowDialog`), `lib/wallet.dart:144` (`WalletItemRestoration → WalletRecoveryPage`,
  `onWalletRecovered(accessStructureRef)`), and `lib/wallet_list_controller.dart:94`
  (`selectRecoveringWallet(RestorationId)`). The landing screen's "Restore wallet — Use an existing device
  key or load a physical backup" is the entry (seen on a fresh app). NO existing test drives this flow, so
  the test must discover its semantic labels during implementation.
- **Delete mechanism** (options the user named): clear the app data, OR a delete/forget tool. Relevant code:
  `secure_key_provider.dart` `deleteKey()`, `lib/device.dart:378` ("This will wipe the key from the
  device" — that WIPES A DEVICE, which we must NOT do — the devices must retain shares). The delete must
  remove only the APP/coordinator's wallet, leaving the virtual devices' shares intact.
- **Harness primitives** already present: `createWallet(...)`, `plug([n])`/`unplug([n])` (device connect),
  `setChain([...])`, `device(n).holdConfirm(...)`, `addDevice()`, `waitFor`/`tapUntil` (sim_harness.dart).

## Task 1 — a wallet-delete primitive that keeps device shares

Delete the app/coordinator's wallet while the virtual devices RETAIN their key shares, and expose it to the
harness. The mechanism EXISTS and is coordinator-only: the in-app "Delete wallet" action
(`lib/settings.dart:926`, `lib/wallet_more.dart:193`) calls `coord.deleteKey(keyId:)` — it forgets the
wallet from the coordinator WITHOUT wiping the devices (that is the SEPARATE `device.dart:378` "wipe the key
from the device", which we must NOT do). Add a harness primitive (e.g. `h.deleteWallet()`) that drives that
UI action (or calls the same coordinator path), commenting exactly what it clears vs preserves.
CRUCIAL: verify the virtual devices' shares SURVIVE the delete — they are the recovery source. The sim
devices are the in-process `simDevicePool` (Rust-side, driven over the app channel); confirm their key state
persists independently of the coordinator's wallet (it should — frostsnap separates coordinator from
devices), or recovery is impossible. (An alternative is clearing app data + relaunch — the "reinstalled the
app" case — but only if the device shares live OUTSIDE that cleared state.)
- **Acceptance:** after the primitive runs, the app shows NO wallet (back at the create/restore landing),
  and each virtual device still reports holding its share.

## Task 2 — the recovery driver test

Add `test_driver/recovery_drive.dart` (auto-discovered by `simctl`, like the others):
1. **Setup**: create a 2-of-3 wallet over a 3-device chain (reuse the `keygen_2of3` steps or a shared
   helper) and land at wallet home. Record an identity to compare later — the wallet NAME and a stable
   artifact (e.g. a receive address / descriptor).
2. **Delete**: run the Task 1 primitive → assert the wallet is gone from the app, devices retain shares.
3. **Recover**: enter the recovery flow (`WalletRecoveryFlow`) and plug the devices SEQUENTIALLY
   (`h.plug(1)`, then `h.plug(2)`, ...), driving each discovery step, until the threshold (2 of 3) is
   reached and the app fires `onWalletRecovered` → wallet home.
4. **Assert**: the recovered wallet EQUALS the original — same name, and the same descriptor/receive address
   (a real-hw semantic: recovery reconstructs the SAME key, not just "a wallet"). With regtest, optionally
   confirm the recovered wallet sees the original's on-chain funds.
   Print a `RECOVERY_OK: ...` sentinel on success.

Keep it a leaf-only test — no portable logic re-implemented; drive through the same `SimHarness` API the
other tests use. Note the observation-floor rule (assert persistent states, not transient counters).

## Task 3 — run it on both backends

- Confirm the test is discovered + runs via `./simctl test recovery` on **host**, green.
- Run it on **android** (`./simctl test recovery --android`) — the sim-unify-app-host self-boot makes this
  work; a per-device plug/recover flow on an emulator is good extra coverage. If a real gap surfaces
  (e.g. the delete-app-data path differs on android), handle it in Task 1's primitive.
- **Acceptance:** `recovery` green on host AND android, 0 orphaned emulators.

## Notes

- Recovery threshold semantics: 2-of-3 means recovery must succeed after plugging exactly 2 devices and NOT
  before — assert both (don't recover early on 1 device) to avoid a green-but-wrong test.
