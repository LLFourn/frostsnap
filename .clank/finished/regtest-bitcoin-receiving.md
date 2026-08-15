# regtest-bitcoin-receiving
# A real regtest bitcoind + electrs spawned with the sim session, plus a tray faucet column

## Goal
Let a sim session receive REAL bitcoin on regtest. A new tray column ("Test BTC" / faucet)
shows a spendable test balance and a button to send funds to the open wallet's receive
address; the funds arrive over a genuine `bitcoind` regtest node + `electrs` electrum server,
synced by the app's normal chain backend. The node + electrs + faucet are managed through the
`./simctl` CLI (sim-14) and can be kept up across many test runs.

## Why
The sim today drives keygen end to end but the wallet is offline — you can generate a key and
see a receive address, but no coins ever land, so the receive/balance/tx-history UI and the
chain-sync path are never exercised in the sim. Wiring a regtest node + faucet into the
session makes "receive bitcoin" a one-click thing to demo and test, on the real electrum sync
path (not a mock).

## Key finding: the app already speaks regtest
The app ALREADY supports `bitcoin::Network::Regtest` and ALREADY runs a per-network
`bdk_electrum_streaming` chain sync (`frostsnap_coordinator/src/bitcoin/chain_sync.rs`), with a
default regtest electrum URL of `tcp://localhost:60401`. Wallet network is fixed at keygen via
`KeyPurpose::Bitcoin(Network)`. So the app needs almost NO change:
- point its regtest electrum URL at the electrs we spawn (a small injection seam — see Task 3),
- create the sim wallet as Regtest so funds land.

This keeps the LEAF-ONLY spirit of the sim epic: the production chain-sync LOGIC is unchanged
(it speaks electrum to whatever server it's told) — at most the regtest DEFAULT url/port is set
(debug, regtest-only); the sim only adds, ABOVE the app, a local node + electrs + faucet and
points the app's regtest wallet at it.

## Core architecture (read first)
Spawn the node ABOVE the app, not inside it, and make it a SHARED, persistent-capable backend
that sessions/tests attach to (req 3 — future multi-instance for remote keygen/signing sharing
one regtest state; and keep one node up across a batch of tests for speed):

```
  regtest-backend (standalone Rust process, tools/sim_regtest)
    ├─ bitcoind (regtest) + electrs                      via the `electrsd` crate
    ├─ faucet = bitcoind's OWN wallet (no bdk):          mine 101 blocks to mature a coinbase
    ├─ control socket (unix, well-known path):           {fund <addr> <amt>, mine [n], balance,
    │                                                      faucet_address}
    └─ publishes its electrum URL to a well-known file   (e.g. tcp://127.0.0.1:PORT)

  the ./simctl layer (serve / SimHarness.launch / runScenario)
    ├─ ATTACH to a running backend if one exists (well-known socket responds), else SPAWN one
    │     (a node started explicitly via `./simctl regtest up` persists across tests; a node
    │      auto-spawned for a single session is torn down with that session)
    ├─ launch app instance(s), injecting the electrs URL as the regtest electrum server
    │     (one node, N apps — the node is not owned by any app)
    └─ tray "Test BTC" column (in the app) drives the faucet over its control socket:
          open wallet's next receive address (FRB) → faucet.fund(addr, amt) → mine →
          the app's normal regtest chain sync sees the tx → balance/tx UI updates live.
```

Why a separate Rust process (not in `load_sim`): the bitcoind/electrs spawn crate is Rust, the
harness/CLI layer is Dart, and the node must outlive/!belong-to any single app so apps (and test
runs) can share it. So the `./simctl` layer spawns/attaches a small Rust `regtest-backend` binary
and points the app(s) at its electrum URL. Mirrors the existing device-socket pattern (a control
unix socket the Dart side drives, like `SimDeviceChannel`).

Shared-state note: a shared chain accumulates blocks/funds across tests, but each test creates
a FRESH regtest wallet (fresh descriptors → unique addresses), so funds it receives are
isolated to its own addresses even on a shared node. Tests must not assume a pristine chain
height or a zeroed faucet balance — assert on the wallet's own received amount, not absolutes.

## How it plugs into the `./simctl` CLI (sim-14)
sim-14 made `./simctl` the single sim entrypoint and removed sim recipes from the justfile; this
feature adds ONLY `./simctl` subcommands + one driver test file, never a justfile recipe:
- `./simctl regtest up|down|status` — node lifecycle. A simctl subcommand special-cased like
  `serve`/`test` (it manages the standalone `tools/sim_regtest` Rust backend; it does NOT connect
  to an app daemon). It `cargo run`s/builds the backend; it needs NO FRB codegen, so it is NOT
  added to the launcher's `just maybe-gen` step (which stays serve/test-only).
- `./simctl serve` (and `runScenario`) attach to a running backend or auto-spawn an ephemeral one
  (consider a `--regtest`/`--no-regtest` flag), injecting the electrum URL into the app launch.
- `./simctl fund <amt> | mine [n] | btc-balance | faucet-address` — faucet ops. `fund` needs the
  open wallet's receive address, so it forwards through the running session (which holds a
  `FaucetChannel`); node-only ops may talk to the backend's control socket directly.
- The e2e test is a new `test_driver/regtest_*_drive.dart` file — the sim-14 `./simctl test`
  runner auto-discovers it (`./simctl test regtest_receive`), so it needs NO recipe and NO new
  CLI plumbing.

## Crates (from bdk's test tooling, ~/src/bdk)
- `electrsd` (0.38.x) — manages BOTH `bitcoind` and `electrs`. `ElectrsD::with_conf(...)`,
  `electrsd.electrum_url`; `bitcoind` is re-exported as `electrsd::bitcoind` (`BitcoinD`,
  `client.new_address()`, `client.generate_to_address(..)`, `client.send_to_address(..)`,
  `getbalance`) — that IS the faucet, no `bdk_wallet` needed.
  Features: `bitcoind_download` + `bitcoind_28_2` + `esplora_a33e97e1` (pins/auto-downloads
  the electrs binary) + `legacy`.
- Binary acquisition: rely on `electrsd` auto-download (the `*_download` features fetch the
  pinned bitcoind/electrs on first build/run). `BITCOIND_EXE` / `ELECTRS_EXE` still override
  for free if ever needed (offline), but auto-download is the default — no manual binary mgmt.
- Optionally crib the ~100-line spawn/mine/send glue from `bdk_testenv`'s `TestEnv`
  (`~/src/bdk/crates/testenv/src/lib.rs`) instead of depending on it.

## Decisions (resolved)
1. **Faucet = bitcoind's built-in wallet** via `electrsd::bitcoind` (mine 101 blocks to mature
   a coinbase, then `send_to_address` to the wallet). No `bdk_wallet` — we don't need a wallet
   under test for the faucet, so keep it to the one crate.
2. **Binary acquisition = `electrsd` auto-download** (pinned via features). No local binary
   management; env-var override remains available but unused by default.
3. **Shared, persistent-capable node.** The backend is decoupled from a single test/session:
   `./simctl regtest up`/`down` runs a long-lived node; sessions and `runScenario` ATTACH to a
   running one (and DON'T tear it down), or auto-spawn+teardown an ephemeral one if none is up.
   Keeps one node alive across a batch of tests for speed and toward future multi-app sharing.
4. **New crate `tools/sim_regtest`** (binary) — keeps the electrsd/bitcoind dep out of the
   device sim crate. **Sim wallets are created as Regtest** so faucet funds land.
5. **Point the app at our electrs (user-sanctioned latitude: change the regtest default and/or
   seed via env).** Two viable mechanisms; implementer picks the lowest-friction one:
   - **Fixed-port alignment (preferred, zero per-launch injection):** bind the spawned electrs to
     a FIXED port (electrs `--electrum-rpc-addr`) and make that the app's DEFAULT regtest electrum
     URL. If the existing default `tcp://localhost:60401` is usable, bind electrs there and the
     app connects with no per-launch step at all. (User OK'd editing the regtest default.)
   - **Env-var seed (robust to a dynamic port):** the `./simctl` layer exports the published
     electrs URL (e.g. `FROSTSNAP_REGTEST_ELECTRUM`) which `Settings::new` reads and applies via
     `set_electrum_server(Regtest, url)` at startup.
   Either way the change is tiny + regtest-only; other networks and the chain-sync LOGIC are
   untouched. Caveat: a fixed port suits the shared-single-node model (one electrs up); if
   ephemeral/parallel nodes ever need distinct ports, use the env-var seed.
6. (Carried) Funding UX: MVP funds the currently-open wallet's next receive address.

## Tasks (refine at implementation)
1. **`tools/sim_regtest` crate/bin**: spawn bitcoind+electrs via `electrsd`; mine 101 blocks to
   fund the bitcoind wallet (faucet); control unix socket with `fund`/`mine`/`balance`/
   `faucet_address`; publish the electrs URL to a well-known path; clean teardown (kill
   children, remove datadir + socket — no residue, matching the sim's teardown discipline).
   `up`/`down`/`status` lifecycle for a persistent node.
2. **`./simctl` layer wiring**: `SimHarness.launch` / serve / `runScenario` ATTACH to a running
   backend (well-known socket/URL) or auto-spawn+own an ephemeral one; inject the electrs URL
   into the app launch; expose a `FaucetChannel` (Dart unix-socket client, like
   `SimDeviceChannel`). Only tear down a backend this session spawned. Share one backend across
   multiple app instances.
3. **App ↔ regtest electrs** (decision 5): either bind electrs to the app's default regtest port
   (zero injection) or seed the URL via env (`FROSTSNAP_REGTEST_ELECTRUM` → `Settings::new` →
   `set_electrum_server(Regtest, url)`). Ensure sim wallets are Regtest. Chain-sync LOGIC
   unchanged — at most the regtest DEFAULT url/port is adjusted (regtest-only, debug).
4. **Tray "Test BTC" column**: faucet balance; "Fund wallet" button (open wallet's receive
   address via FRB → `faucet.fund(addr, amt)` → mine); "Mine N blocks" button. Balance/tx
   update through the app's existing `TxState` stream — assert it does.
5. **`./simctl` subcommands (no justfile recipes — sim-14 pattern)**: `regtest up|down|status`
   (node lifecycle, special-cased like `serve`/`test`, `cargo`-builds the backend, NOT in the
   `just maybe-gen` path); `fund <amt>` / `mine [n]` / `btc-balance` / `faucet-address` (faucet
   ops; `fund` forwards through the running session for the wallet address). Update simctl usage.
6. **e2e test**: a `test_driver/regtest_*_drive.dart` (run via `./simctl test <stem>` — the
   sim-14 runner auto-discovers it, no recipe): against an attached/auto-spawned node, create a
   Regtest wallet, fund its receive address via the faucet, mine a block, assert the wallet's
   `TxState` balance reflects the received amount (the real electrum sync path), then tear down
   with no residue. Assert on the wallet's own received delta, not absolute chain/faucet figures
   (shared-state safe).

## Acceptance
- `./simctl serve` brings up (or attaches to) a regtest node + electrs + faucet alongside the
  app; the tray shows a faucet balance; "Fund wallet" sends coins that appear in the wallet's
  balance/receive UI after a mined block (real electrum sync, not a mock).
- `./simctl regtest up` starts a node that survives multiple `runScenario`/serve sessions; those
  attach to it and do NOT tear it down; `./simctl regtest down` stops it.
- The node/electrs/faucet are spawned by the `./simctl` layer, NOT by `load_sim` — a second app
  instance can attach to the same electrs.
- e2e test green via `./simctl test <stem>`: fund → mine → wallet balance updates; assertions are
  shared-state-safe. Teardown of an OWNED node leaves no residue (no stray bitcoind/electrs,
  datadir + sockets removed); an attached shared node is left running.
- NO new justfile recipes (only `./simctl` subcommands + one driver file — sim-14 invariant);
  the justfile is unchanged by this feature.
- Production chain-sync LOGIC unchanged (leaf-only): the only app-side change is pointing the
  REGTEST electrum URL at our electrs (a default-value/env tweak, regtest-only) + creating a
  Regtest sim wallet. Other networks + the sync code path untouched; esp/embedded untouched.

## Depends on
sim-5..sim-14. Specifically **sim-14** (the `./simctl` CLI): regtest/faucet are added as
`./simctl` subcommands and the e2e as a `*_drive.dart` run by `./simctl test`, never a justfile
recipe; the launcher's `just maybe-gen` gen-ensure (serve/test) is reused unchanged. Reuses the
device-socket control-channel pattern (sim-8/9) for the faucet, and the tray (sim-12/13).

## Future (out of scope, but the design must not preclude)
Multiple app instances sharing one regtest node for remote keygen/remote signing tests — hence
the node lives above the app, is addressed by URL, and is shareable/persistent.

## Status (complete)
All tasks implemented and verified end-to-end (commits `cd6b817d`..`bd0b9e97`):
- Task 1 `tools/sim_regtest` (bitcoind+electrs+faucet, control socket, singleton lifecycle).
- Task 2 `./simctl` wiring: attach-or-spawn, ownership authoritative via the backend's PID,
  shared `SimFaucet` client, deterministic reap on teardown.
- Task 3 app↔regtest electrs (env-seeded URL) + sim wallets default to Regtest via
  `FrostsnapContext.defaultNetwork` (no sim branch in the wallet-creation flow).
- Task 4 "Test BTC" tray column: faucet balance, electrum URL, Mine, and a generic
  fund-an-address control.
- Task 6 e2e `regtest_receive_drive.dart` (`./simctl test regtest_receive`): keygen → fund the
  wallet's real receive address → assert the balance over the genuine electrum sync path;
  shared-state-safe (asserts the wallet's own received amount). Teardown leaves no residue.

Deviation: **Task 5's session-aware `fund <amt>`** (auto-resolving the open wallet) is superseded
by the generic fund-an-address surface — the tray field and `./simctl regtest fund <addr> <sats>`
— so neither the tray nor the CLI needs to reach into wallet selection. Invariants hold:
esp/embedded untouched, and the only justfile edit extends the dart-format glob to `./test` (no
new recipes; sim commands stay on `./simctl`).
