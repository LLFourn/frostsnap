# sim-regtest-unconfirmed-receives
# Faucet receives land UNCONFIRMED until you Mine; show block height in the Test BTC pane

## Goal
Make the regtest faucet behave like a real chain for testing the unconfirmed → confirmed
flow: funding an address broadcasts a mempool tx that the wallet sees as UNCONFIRMED, and it
only confirms when you press "Mine". Also surface the current block height in the tray's "Test
BTC" pane so you can see the chain advance.

## Why
Today `Regtest::fund()` (tools/sim_regtest/src/lib.rs) does `send_to_address` then `self.mine(1)`
— it auto-mines a block on top of every funded tx, so the receive is confirmed instantly and the
unconfirmed/pending UI path is never exercised. We want to test that path (and demoing it is more
realistic). There's also no visible block height, so "Mine" has no obvious effect to watch.

## Scope
- `tools/sim_regtest` (Rust): faucet backend.
- `frostsnapp/lib/sim_faucet.dart` + `frostsnapp/lib/sim_device_tray.dart` (the Test BTC pane).
- `frostsnapp/test_driver/regtest_receive_drive.dart` (e2e — must be updated, see Tasks).
- Sim-only; production app + esp/embedded untouched. The app's own unconfirmed/pending handling
  is NOT changed — we only stop forcing a confirmation.

## Tasks
1. **fund() broadcasts only.** Drop the `self.mine(1)` from `Regtest::fund` so the tx stays in the
   mempool. Nudge electrs to index the mempool tx (`electrsd.trigger()`, and if needed a short
   wait until electrs reports the tx) so the app's electrum sync sees the UNCONFIRMED receive
   promptly. `mine` stays the one and only way to confirm.
2. **Block height read-out.** Expose the chain tip (the backend already tracks `tip`) over the
   control socket — extend the `ping` reply or add a `height` command — and add
   `SimFaucet.blockHeight()`. Show "Block height: N" in the Test BTC pane (mono, near the electrum
   line); it should tick up when Mine is pressed.
3. **e2e test update.** `regtest_receive_drive.dart` currently asserts a *confirmed* balance
   because fund auto-mined. Update it to the real flow: fund → assert the wallet shows the receive
   as PENDING/unconfirmed (balance not yet available), then drive Mine (faucet) → assert it becomes
   confirmed/available. Poll for electrum-sync latency; keep assertions shared-state-safe (the
   wallet's own amount, not absolute chain figures).

## Acceptance
- `./simctl regtest fund <addr> <sats>` (and the tray's Fund) leaves the wallet receive UNCONFIRMED
  (pending in the wallet UI); `./simctl regtest mine` (and the tray's Mine) confirms it.
- The Test BTC pane shows the current block height and it advances on Mine.
- e2e green via `./simctl test regtest_receive`: unconfirmed-after-fund, confirmed-after-mine.
- Sim-only; CLI keeps parity with the tray; analyze + format clean; no orphaned processes.

## Depends on
regtest-bitcoin-receiving (the faucet + Test BTC pane) and sim-tray-redesign (the pane layout).
