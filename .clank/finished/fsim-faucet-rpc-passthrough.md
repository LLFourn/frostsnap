# fsim-faucet-rpc-passthrough
# A bitcoind RPC escape hatch, so one-off chain queries stop growing library code

Commit `9c543ac` (frostsnap-ci, send-plan-refactor) needed to assert which derived
address a transaction output landed on. The test itself was fine — but it had to touch
THREE fsim library files to exist: a new `derive_address` control verb, a miniscript
helper in the backend, and a `SimFaucet` wrapper. That is the pattern to kill: every
new test-local question about the chain or a descriptor currently costs a backend verb
plus a Dart wrapper, reviewed and maintained forever, for logic only one test wants.

The general capability is already sitting there: the regtest backend holds a full
`bitcoincore_rpc` client, and bitcoind itself can answer the whole class —
`getdescriptorinfo`, `deriveaddresses`, `getrawtransaction`, `decodepsbt`,
`scantxoutset`, … What's missing is a passthrough.

## Milestone 1 — the passthrough

- `tools/sim_regtest` control protocol grows ONE verb:
  `{"cmd":"rpc","method":"<name>","params":[…]}` → `{"ok":true,"result":<json>}` —
  forwarded verbatim to bitcoind via the existing client's generic `call`, errors
  surfaced as the control channel's normal error shape. No allowlist: this is a
  throwaway regtest backend owned by the test session; the passthrough IS the escape
  hatch. Documented in the protocol comment block with the others.
- `SimFaucet.rpc(String method, [List<Object?> params])` → decoded JSON result. One
  wrapper, forever — new needs compose in the test file instead of adding verbs.
- COMMANDS.md row + documented-methods coverage; the row's doc points at the recipe
  below so the next author reaches for composition first.
- Out of scope: re-expressing the existing narrow verbs (`fund`, `mine`,
  `watch_descriptor`, …) over the passthrough — they wrap real backend logic
  (electrs sync waits, watch wallets) and have many callers; this plan only stops the
  GROWTH.

## Milestone 2 — prove 9c543ac needs no library code

The derive-an-address need reduces to a test-side recipe over the passthrough, using
only bitcoind: take the app's `walletDescriptor()` (already on the harness), rewrite
the multipath `<0;1>` segment to the wanted keychain, drop the stale checksum, ask
`getdescriptorinfo` for the canonical one, then `deriveaddresses` at the wanted index.

- A new e2e (`regtest_descriptor_rpc_drive.dart`), TEST FILE ONLY, proves the whole
  chain end to end and GREEN today: create a wallet, read the app's displayed
  receive address, independently derive external index 0 via the recipe, assert they
  are equal. This is exactly the derivation the change-index test needs (keychain 1 +
  a balance assertion instead of equality), demonstrating that test now costs zero
  library edits.
- The recipe lives as a short worked example in COMMANDS.md next to `rpc()` — the
  point of the milestone is that the NEXT author copies a recipe, not a diff across
  three library files.

### Sufficiency validation (user-requested, 2026-08-15)

`9c543ac`'s test was ported verbatim onto the passthrough — its backend
`derive_address` calls replaced by the recipe, zero library edits — and run here. It
executed the full flow (wallet, fund, sign on-device, broadcast, mine) and failed at
exactly its designed assertion with the identical diagnostic: change "landed at
internal index 2 — change indices were burned before the transaction was built". The
API is sufficient, and the index-burn bug is confirmed live on this branch. The port
is deliberately not a deliverable of this plan — red by design until the
send-plan-refactor fix lands, it belongs in that fix's change set, and is trivially
re-created from `9c543ac` plus the COMMANDS.md recipe.

## Constraints

- No WHAT comments; document contracts (the passthrough's error shape, the recipe's
  why) not narration.
- Run what CI runs: `just lint-app`, `just test-ordinary --release --all-features
  --locked`; the new e2e green on host and android lanes. Keep `pubspec.lock` out of
  commits; reap emulators after android validation.
