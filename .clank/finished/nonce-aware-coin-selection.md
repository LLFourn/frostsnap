# nonce-aware-coin-selection
# Make coin selection aware of the nonce limit

A signing session uses **one nonce stream per device**, and a stream holds a finite number of nonces
(`NONCE_BATCH_SIZE = 30`). Each transaction input needs one signature, so one nonce per input per
signing device. Today coin selection knows nothing about this: it will happily select 40 inputs for a
wallet whose devices can only sign 30, and the failure surfaces at `start_sign` → `NotEnoughNonces`,
after the user has committed to an amount and picked signers.

**Milestone 1 (this revision) settles the design.** Milestone 2 implements it.

## The design

### The model

A device's usable capacity for one transaction is the **largest available nonce count among its
streams not held by an active signing session** — not the sum across streams, because a session
cannot span streams. This is exactly what the app-level `Coordinator::nonces_available`
(`frostsnapp/rust/src/coordinator.rs:417`) already returns: `.values().max()` over the per-stream map
from `frostsnap_core`, which already excludes `all_used_nonce_streams()`.

Over the chosen access structure's devices:

- **candidates** = devices with capacity > 0 (a zero-nonce device is not a candidate signer, per
  requirement 1 — it does not drag the limit down, it just can't sign);
- if **|candidates| < threshold** → **NoSpend**: no transaction is signable at any amount;
- otherwise the per-transaction input cap is **L = min capacity over candidates**.

Why `min` over *all* candidates rather than the threshold-th-largest capacity: every candidate has
capacity ≥ L, so **any** threshold-sized subset the user later picks on the signers page can sign an
L-input transaction. The amount → signers page order stays valid with zero new coupling between the
pages; signer choice can never invalidate the transaction that was built. The cost is conservatism
(the best subset could sometimes sign more), which is precisely what the long-term
devices-before-amounts flow (requirement 5) would recover. This design keeps that door open: the cap
is a number computed *from a device set*, so the future flow just feeds it the chosen devices instead
of all candidates — nothing downstream changes.

### Where it is enforced

- `CoordSuperWallet::send_to` and `calculate_avaliable_value`
  (`frostsnap_coordinator/src/bitcoin/wallet.rs`) gain an explicit **`max_inputs` parameter**. The
  wallet stays nonce-ignorant — the cap arrives as a plain number. No `frostsnap_core` changes.
- The number is computed in the app layer (`frostsnapp/rust`), where coordinator, access structure
  and wallet already meet (`BuildTxState`). It is **recomputed at each use, never cached** — it
  changes as sessions start/finish and devices replenish.
- Every real path passes it: `BuildTxState::fee()`, `try_finish()`, `available_amount()`, and
  `send_to`'s own internal available-value computation for send-max recipients (wallet.rs:432). The
  bridge-level `SuperWallet.send_to` endpoint (no Dart callers) gains the parameter too, so no path
  can silently bypass the cap.

### Selection algorithm (`send_to` with cap L)

1. Run the natural selection exactly as today (BnB `LowestFee`, with the existing
   `select_until_target_met` fallback). If it selects ≤ L inputs, done — requirement 3 forbids
   pre-constraining a selector whose natural answer already fits.
2. Otherwise **truncate the selection to its L largest-by-value inputs** (requirement 3) and
   recompute change under the existing `ChangePolicy`. If the target is still met, done.
3. Otherwise **re-run the selection restricted to the L largest-by-value candidates**.
   Pre-constraining is justified here because the natural answer did not fit and its truncation
   fell short (it may have chosen many small coins for a changeless solution). If even this misses
   the target, fail with a nonce-limited insufficient-funds error.

Step 3 keeps the amount page honest: "available" is computed over the L largest utxos, so any amount
≤ available *is* reachable within L inputs — but not necessarily by truncating the natural
selection. With step 3 the promise always holds; the terminal error is reachable only by callers
that bypassed the amount page.

Fees and change: truncation removes input weight, so the fee falls and change is recomputed by the
same policy; change below dust is dropped into fees — today's rules applied to the truncated set.

### Cap-aware available amount

`calculate_avaliable_value(max_inputs = L)` selects the **L largest effective candidates** instead of
all effective candidates. Everything downstream is free: the amount page ceiling and the existing
"Exceeds max by N" inline error now reflect the true signable maximum, send-max sends the capped
maximum, and NoSpend surfaces as available = 0.

### The one dialog

One new dialog, owned by the amount page, explaining the nonce limitation. Triggers:

- entering the amount page in **NoSpend** state — "this balance can't be spent until a device
  replenishes signing nonces; connect a device";
- the first actual collision with the cap: **send-max** tapped while capped available < uncapped
  available, or a **typed amount** in (capped, uncapped] — "your devices' remaining signing nonces
  limit this transaction to L coins — at most X can be sent right now".

Shown at most once per send-flow entry; afterwards the existing inline error carries the constraint.
The signers page keeps its existing zero-nonce handling unchanged — by construction of `min`, any
threshold subset it permits can sign the built transaction.

### Deliberately not handled

- **Devices-before-amounts** (requirement 5): enabled by the cap-from-device-set shape, not built.
- **No nonce reservation at build time.** The cap can go stale between the amount page and
  `start_sign` (another session may claim a stream concurrently). The existing `NotEnoughNonces`
  failure at `start_sign` remains the backstop for that race.
- **No automatic splitting** of an over-cap spend into multiple transactions.
- **Message/nostr signing untouched** (single nonce; the UI already checks `noncesAvailable >= 1`).
- **Replenishment policy untouched** (`N_NONCE_STREAMS = 4`, `NONCE_BATCH_SIZE = 30`).

## Milestone 2 — implementation

Roughly three commits:

1. **frostsnap_coordinator**: extract the selection so the natural → truncate → restricted algorithm
   is a function over real `bdk_coin_select` candidates, testable with real selection math and no
   mocked nonce store (the cap enters as a number). Thread `max_inputs` through `send_to`,
   `calculate_avaliable_value`, and the internal send-max path. Tests: over-cap natural selection
   truncates to the largest inputs with change recomputed; truncation shortfall falls through to the
   restricted re-run; restricted re-run failure errors; ≤-cap natural selection untouched.
2. **App layer + Dart**: cap computation (candidates / threshold / min) in `frostsnapp/rust`,
   exposed on `BuildTxState` (cap, capped and uncapped available, NoSpend) — then the dialog and its
   two triggers in `wallet_send.dart`. Nothing else in the UI changes.
3. **fsim videos** (`./fsim test <stem> --android --jobs 1 --nocapture --test-timeout 1800`; read
   `frostsnapp/test_driver/COMMANDS.md` and `sim_harness.dart` first):
   - **success**: an ordinary send with few inputs, for contrast;
   - **truncation**: fund the wallet with >30 small utxos (fresh devices → L = 30), send-max →
     dialog, resulting tx spends exactly the 30 largest inputs, signs and broadcasts;
   - **no nonces**: exhaust a device's streams by leaving sign sessions pending (streams held by
     active sessions don't count), reaching NoSpend → amount-page dialog, plus the signers page's
     existing zero-nonce marking.

## LLFourn's requirements — constraints, not suggestions

1. **The limit is `min` over all devices that have non-zero nonces available.** A device with zero
   available nonces does not drag the limit to zero — it is simply not a candidate signer.
2. **Do not make the UI more complicated than it currently is.** A dialog warning that the user cannot
   spend above X because available nonces are limited is acceptable. Anything more elaborate is not.
3. **Truncation rule:** when the first coin selection selects **more** inputs than the limit, truncate
   to the **largest** inputs. Only then — do not pre-constrain the selector if its natural answer
   already fits.
4. **Failure-mode videos are part of the deliverable**, including the case where a device has no
   nonces available at all.
5. **The correct long-term solution is probably to choose devices _before_ choosing amounts.** Noted
   and designed-for above; not built here.

## ⚠️ Your base is a KNOWN-RED fork master — read before trusting any CI result

This branch is based on fork master `6d42d364`, which is **red for reasons that are not yours**:

- **`Test ordinary libraries`** — `backup_typist::tests::types_a_backup_on_a_running_device_through_the_protocol`
  panics with `entered words resolved to an invalid checksum`. A timing-dependent dropped keypress; it
  passes locally and fails under CI load.
- **`Flutter Analyze`** — `test/label_diagnostics_test.dart:202` passes 6 positional args to
  `AppSession.new`, which took a 7th (`_liveness`). `_AppLiveness` is library-private, so the fix is an
  API decision, not a call-site tweak.

Both are queued to the fsim team (`master-red-typist-and-analyze`, priority 50). **Do not diagnose
them, and do not read them as evidence about your change.** The PR cannot produce a green CI result
until rebased onto a master carrying those fixes — say so in the PR rather than presenting a red run
as expected.

## Constraints

- **No WHAT comments.** Only WHY, and only when the why isn't obvious.
- **Prefer no test to a mocked one.** A test that mocks the nonce store to assert arithmetic proves
  nothing about whether real coin selection respects the cap.
- **Keep the UI change to roughly one dialog** — settled above: one dialog, two triggers.
- Run what CI runs before claiming green — `just lint-ordinary --release --locked` and
  `just test-ordinary --release --all-features --locked`, reading exit codes directly rather than
  through a pipe.
