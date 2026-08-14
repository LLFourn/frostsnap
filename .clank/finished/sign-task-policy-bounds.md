# sign-task-policy-bounds
# Temporary: bound what a sign task may present as ours

**This is an explicitly temporary stop-gap**, agreed as such, while the wallet's account and
address-issuance model is still implicit. It will be revisited. Say so in the code, at the check,
so the next reader knows it is a holding position and not a considered final model.

In `WireSignTask::check` and nowhere else — no coordinator guards, no changes to address issuance
or change allocation:

Every **locally-owned output** must be in `BitcoinAccount::default()` and have `index < 200_000`.

Outputs only. An input path is self-certifying — `Input::txout` builds the prevout from the
claimed path's own spk, so the sighash commits to it and a forged path signs against a prevout
that is not on chain. Policing inputs would buy nothing and would strand a coin a PSBT
legitimately imports, which is the cost an earlier draft of this plan accepted and no longer
needs to.

The wrong-key check keeps covering every owner and is unchanged.

`200_000` is a chosen number. It bounds the space any future recovery sweep would have to cover:
with it, everything the device has called ours sits in a scannable range; without it a sign task
can park a "change" output where no scan will reach. Do **not** justify it as being above what
ordinary use reaches — chain activity moves `last_revealed` too, so that is not a property the
wallet controls.

## The cost, known and accepted

**The rule can disagree with the wallet.** `check` alone is bounded; the coordinator is not. An
honest wallet can allocate change or reveal an external address at or past `200_000` and then have
the device reject its own task. Reaching it is implausible for change (200,000 change outputs, or
a dust campaign that must make nearly every index below it used) and cheaper for external, where
`apply_update` feeds chain-reported `last_active_indices` into `reveal_to_target_multi` and a
third party can walk `last_revealed` forward roughly one dust output per 25 indices. The
consequence there is a refused self-send, not lost or unspendable funds.

Closing this properly means one shared address-issuance/allocation boundary that every path
routes through — `next_address`, `get_address_info`, `addresses_state`, `search_for_address`, the
device `verify_address` flow, and change allocation — with `next_address` becoming fallible. That
is the cleanup, and it is out of scope here by decision, not oversight.

## Acceptance

**One test, a handful of assertions.** This is a stop-gap that will be replaced, so it does not
earn a suite — resist a test per rule, per keychain, and per boundary. The invariants it checks
are three lines of code; pin them once and move on.

That one test covers:

- a locally-owned output at `200_000` rejected, at `199_999` accepted;
- a locally-owned output outside the default account rejected;
- a locally-owned input outside the default account **accepted**, pinning the outputs-only scope.

Beyond that: existing sign-task tests still pass, `cargo test` green, `cargo clippy` clean under
`RUSTUP_TOOLCHAIN=stable`.

## Notes

- Depends on `sign-task-index-bounds` landing first; the index type is already in place by then.
- Do not add coordinator guards here. If the disagreement in rule 2 turns out to bite before the
  cleanup, raise it rather than patching it in.
- **No WHAT comments.** Only WHY, and only where the why is not obvious. Delete rather than trim.
- Match the surrounding style in `frostsnap_core`.
