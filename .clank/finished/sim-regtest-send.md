# sim-regtest-send
# Full lifecycle in the sim: keygen → receive → SEND (device-signed) back to the regtest node

## Goal
Prove (and make playable) the whole wallet lifecycle on regtest: create a wallet, receive test
BTC from the faucet, then SEND from the wallet — signed on the virtual device — to the regtest
node's own wallet address, confirmed over the real chain. Sending is the remaining half of the
lifecycle and the most involved device-signing path. The send must exercise a real **2-of-3**
wallet (threshold 2, three devices) — not a degenerate 1-of-1 — so multi-device keygen and
multi-signer signing (collecting two signature shares from a chosen subset) are covered, which is
the realistic Frostsnap configuration.

## Why
The sim now does keygen + receive (regtest-bitcoin-receiving, sim-regtest-unconfirmed-receives) but
never exercises SEND: build a tx → sign on the device → broadcast → confirm. A natural, easy-to-set-
up destination is the regtest NODE's own wallet address (the faucet's bitcoind wallet) — funds
return to the node, and the node's balance change is a simple cross-check. The faucet address is
already available (`SimFaucet.faucetAddress()` / `./simctl regtest address`); we just need to make
it easy to send to.

## Scope
- Surface the node wallet address in the tray's "Test BTC" pane (a copyable "Node address" row) so
  a human can send to it. The API exists (`SimFaucet.faucetAddress`); no new backend needed.
- A new e2e driver test (`test_driver/regtest_send_*_drive.dart`), run via `./simctl test`.
- Sim-only; leaf-only (no firmware/esp change — the device signs with the same code as real hw).

## Tasks
1. **Node address in the tray.** Add a copyable "Node address: bcrt1…" row to the Test BTC pane
   (from `SimFaucet.faucetAddress()`), so the destination for a test send is one tap to copy.
2. **e2e send flow.** `regtest_send_drive.dart`: keygen a Regtest wallet → fund its receive address
   from the faucet → mine to confirm → drive Send (enter the node address from
   `SimFaucet.faucetAddress`, an amount < balance) → sign on the device (hold-to-confirm) →
   broadcast → mine → assert the wallet balance dropped by ~amount+fee and the send tx confirms.
   Cross-check the node/faucet balance rose by ~amount. Shared-state-safe (assert deltas on the
   wallet's own funds, poll for electrum-sync latency).
3. **Verify** both via the CLI: `./simctl test regtest_send` green; the tray shows the node address
   and an interactive keygen→receive→send round-trips by hand.
4. **Upgrade the e2e to 2-of-3, signed one device at a time.** Task 2 landed a 1-of-1 as the first
   working slice; raise it to a threshold-2, three-device wallet. Keygen names three devices at the
   default (recommended) threshold of 2, and all three confirm their security check. The SEND is
   built and the two signers selected with EVERY device unplugged (signer selection is nonce-based,
   so connection isn't required); the two signers are then connected ONE AT A TIME to sign — plug a
   device, hold-to-sign, unplug it, plug the next — never two at once, as on real hardware. After
   the send confirms, close the tx dialog and assert the wallet's activity list shows BOTH the
   receive and the send. Drive everything over the harness/CLI (`deviceCount: 3`); no firmware
   change — a 2-of-3 signs with the same code as real hardware.

## Acceptance
- e2e green via `./simctl test regtest_send`: keygen → receive → device-signed send → confirmed,
  with the wallet's balance reduced and the node's balance increased (delta assertions, not
  absolutes).
- The wallet under test is **2-of-3** (three devices, threshold 2): keygen completes across all
  three; the send is BUILT with every device unplugged, then signed by two devices connected ONE
  AT A TIME (never both at once, the third unused); and after confirmation the activity list shows
  BOTH the receive and the send.
- The Test BTC pane shows the regtest node's wallet address, copyable.
- Sim-only; CLI ↔ tray parity; firmware/esp untouched; analyze + format + cargo green; no orphans.

## Depends on
regtest-bitcoin-receiving, sim-regtest-unconfirmed-receives (faucet + receive + height), and the
device-signing flow exercised by the keygen driver tests.
