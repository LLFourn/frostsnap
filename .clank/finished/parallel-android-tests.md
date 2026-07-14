# parallel-android-tests

Let `./simctl test` run multiple **Android** e2e tests at once, each fully isolated:
its **own emulator** AND its **own regtest chain** — the way host tests already
parallelize, each in its own app process + disposable app dir. Interactive
`up`/`serve`/manual-CLI driving stays single-emulator on the shared persistent node
(explicitly out of scope).

## Core model

`./simctl test` runs each test as an isolated `dart run` (`simctl.dart`
`_runTests`). The ISOLATION model differs by platform:

- **Host:** each test's `dart run` launches its own `flutter run -d macos` —
  a separate app process with its own disposable `SIM_APP_DIR` + device sockets.
  So host tests are already independent and could run in parallel.
- **Android:** every `--android` test resolves the **one** shared emulator
  (`_ensureEmulatorBooted` reuses the first running `emulator-*`,
  `simctl.dart`), `pm clear com.frostsnap`s it, and `flutter run -d <that serial>`.
  Two at once collide: same serial, one Android instance of `com.frostsnap`, the
  `pm clear`s race (one wipes the other's wallet mid-test), and the adb-forwarded
  VM-service ports clash. So Android is serialized to a single emulator.

The model that fixes it is the same one the host already has: **each concurrent
Android test gets a DEDICATED emulator.** An Android emulator instance is a fully
isolated VM, so a per-test serial gives **VM + app-process + `pm clear` + per-serial
adb-forward** isolation for free — the test runner grows an **emulator pool +
per-test allocation**, parallel to how it already hands each host test its own app
process.

**A per-test serial does NOT isolate the regtest chain**, which is a single shared
host node (structural fact 1) — so full isolation needs a SECOND per-test resource:
each test gets its own ephemeral regtest backend (bitcoind+electrs+faucet) bridged
to just its emulator. With both — own emulator AND own chain — a test session is
fully isolated, the analogue of how a host test already gets its own app process +
disposable `SIM_APP_DIR`. So **all** tests parallelize, with no shared-chain race to
serialize around.

Boundary to respect: this is **test-runner only**. The interactive single
emulator + its shared persistent regtest node (`up`/`serve`, manual `./simctl <cmd>`
driving) are unchanged and out of scope — those drive ONE session by hand. The pool
must be NAME-isolated from the interactive emulator (structural fact 2), not just "a
different serial".

Structural facts to respect, not patch around:

1. **The shared regtest node is for INTERACTIVE use; each TEST gets its own.** Today
   regtest is a single shared host node — `simctl-up`'s persistent start-if-absent/
   attach (reaped only by `regtest down`/`clean`), bridged to EVERY emulator over
   adb-reverse (sim-android-tray). That's right for *interactive* driving (one live
   chain you reuse across `up` sessions), but it's the one shared state that breaks
   parallel tests: the shared `mine` confirms ALL mempool txs, so a concurrent test's
   `mine` confirms another's still-pending receive, racing its unconfirmed→confirmed
   ("Receiving"→"Received") assertion — exactly the shared-chain race `simctl-up`
   scoped out. So for the TEST pool, **each test starts its OWN regtest backend**
   (bitcoind+electrs+faucet on unique ports + a private datadir), bridged to just its
   emulator and torn down with the test — full chain isolation, so regtest tests
   parallelize too. This relaxes `simctl-up`'s single-shared-node *for the pool
   only*; the interactive shared/persistent node is unchanged.
2. **Pool/interactive separation must be by NAME, not serial range.** Emulator
   serials (5554, 5556, …) are assigned by boot order, not reservable, so "a known
   range" is fragile — a collision is the same wallet-wipe/`pm clear` race we're
   fixing. Use distinct AVD NAMES — the interactive `frostsnap_sim` vs the pool's
   `frostsnap_sim_pool` prefix (`frostsnap_sim_pool` for the `-read-only` case,
   `frostsnap_sim_pool_0..N` for distinct AVDs) — plus an allocation registry (a lockfile of
   pool-owned serials), so `up`/`serve` can never grab a pool emulator and a test can
   never `pm clear` the interactive wallet.

## Tasks

### Task 1 — Emulator pool + allocator
- Bring up N emulator instances on **distinct serials**, all from POOL-OWNED AVD
  names (never the interactive `frostsnap_sim`, per fact 2). Primary mechanism:
  `emulator -avd frostsnap_sim_pool -read-only` runs multiple ephemeral instances of
  a DEDICATED pool AVD (each gets its own copy-on-write overlay; serials
  `emulator-5554`, `5556`, …). If `-read-only` proves unreliable for concurrent
  instances, fall back to N distinct pool AVDs (`frostsnap_sim_pool_0..N`). Either
  way the AVD is pool-owned and state is ephemeral — tests `pm clear` per run anyway
  — so a cold boot per instance is fine.
- An `_acquireEmulator()` / `_releaseEmulator(serial)` allocator: hands a FREE
  pooled serial to a caller (booting a new instance up to a cap, reusing idle
  ones), reclaims it on release. Separated from the interactive
  `_ensureEmulatorBooted` single emulator by **AVD NAME** (the `frostsnap_sim_pool`
  prefix vs the interactive `frostsnap_sim`) + an **allocation registry** (a lockfile of
  pool-owned serials) — NOT a serial range (serials aren't reservable). So
  `up`/`serve` can't grab a pool emulator and the pool can't grab the interactive
  one.
- Each pooled instance gets the full `up --android` provisioning (PIN/unlock/nav)
  before use.
- Acceptance: acquire two serials concurrently, get two DISTINCT booted+provisioned
  emulators; release returns them to the pool; the interactive emulator (if any) is
  untouched.

### Task 2 — Per-session regtest backend (own chain per test)
- Today `ensureRegtestBackend` is a single shared persistent node. Add a per-SESSION
  regtest backend: a test starts its OWN bitcoind+electrs+faucet on **unique ports +
  a private datadir**, returns its electrum URL + control socket, and tears it ALL
  down with the test (no orphans — the per-session node is ephemeral, unlike the
  shared persistent one).
- The `--android` test path bridges THAT session's node to THAT test's emulator
  (adb-reverse electrs + the faucet TCP proxy on its serial, like `up --android`),
  so each emulator talks only to its own chain. The interactive shared/persistent
  node + `regtest up/down/clean` are unchanged.
- Acceptance: two per-session backends run at once on distinct ports; a `mine`/`fund`
  on one does NOT affect the other's chain (height/mempool independent); both reap
  cleanly (no leftover bitcoind/electrs).

### Task 3 — Parallel `./simctl test` on the pool + verify isolation
- `_runTests` runs tests CONCURRENTLY (today a sequential for-loop), bounded by a
  `--jobs N` knob (default = pool cap). Aggregate pass/fail; a non-zero from any test
  fails the run. (Host tests parallelize too — already isolated; a regtest host test
  gets its own per-session node from Task 2.)
- Each test acquires its own emulator + (if it uses regtest) its own per-session
  backend, runs against them (`SIM_FLUTTER_DEVICE=<serial>` + `pm clear` on THAT
  serial + that session's bridge), and releases BOTH on finish (even on failure).
  Report which emulator each test ran on.
- Honest surface: cap N to host resources (emulator + bitcoind/electrs per slot is
  heavy — log the chosen parallelism); if only one emulator can boot, degrade to
  serial rather than pretend-parallelize.
- **Verify isolation:** run two REGTEST android tests at once on distinct emulators,
  each receiving + confirming on its OWN chain, and prove no cross-contamination —
  one test's `mine` must NOT confirm the other's pending receive (the race this plan
  exists to prevent). Confirm interactive `up --android` + its shared node still work
  alongside. If the environment can only boot one emulator, report that honestly
  (verify the allocator + per-session regtest + degrade-to-serial paths instead of
  faking a parallel green).

## Non-goals
- Multiple emulators for INTERACTIVE `up`/`serve`/manual-CLI driving — explicitly
  out of scope (those drive one session by hand).
- Distributed/cross-host test running.
- A general test-sharding/retry framework — just per-test emulator allocation +
  bounded parallelism.
