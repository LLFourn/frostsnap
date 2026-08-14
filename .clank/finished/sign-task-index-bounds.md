# sign-task-index-bounds
# A bip32 index type that validates on decode

`BitcoinBip32Path::index` and `BitcoinAccount::index` are bare `u32`s. BIP32 child numbers split at
`2^31`: below is a normal child, at or above is hardened. Frostsnap's `derive_bip32_in_place`
(`frostsnap_core/src/tweak.rs`) hmacs whatever raw `u32` it is handed and never rejects the
hardened half, while miniscript descriptors — how the wallet actually builds spks — can only
express normal children. So the wire types can currently carry an index that derives fine on the
device and can never be represented by the wallet.

Introduce a newtype wrapping `u32` that can only hold a normal child, and use it for both index
fields. Fallible construction, infallible accessor.

## Why not rust-bitcoin's `ChildNumber`

There is no normal-only type in rust-bitcoin. `bip32::ChildNumber` is an enum over
`Normal`/`Hardened`, so the type carries no guarantee and every use site would have to match.

It is also actively wrong to reach for here. Its `From<u32>` is **infallible** — a high-bit value
becomes `Hardened { .. }` rather than an error — and its `Deserialize` is
`u32::deserialize(..).map(ChildNumber::from)`. Decoding `0x8000_0000` through it silently
succeeds, which is the exact case this plan exists to reject.

Do validate through `ChildNumber::from_normal_idx`, the one API that errors on the hardened half,
rather than hardcoding `1 << 31`. Provide `From<NewType> for ChildNumber` so path-building
interops without a match.

## Validate at deserialization

The range must be enforced **on decode**, not by a later check, so no code downstream has to
remember. That needs a hand-written `bincode::Encode` / `bincode::Decode` / `BorrowDecode` rather
than the derive:

- Encode exactly as the bare `u32` does — the wire format must not change.
- Decode reads the `u32` and fails with a bincode decode error when it is out of range.

## Fix `from_u32_slice` while the types are in hand

`BitcoinBip32Path::from_u32_slice` reads
`let _check_it = ChildNumber::from_normal_idx(path[2]).ok()?;` — validating the keychain segment,
which the `match` above has already narrowed to 0 or 1, so the check cannot fail — while `path[1]`
(account index) and `path[3]` (address index), the two segments carrying an unbounded `u32`, are
never validated. With the new type those two become fallible conversions and the redundant line
goes.

## Expect churn

This ripples through construction and field-read sites in `frostsnap_core`,
`frostsnap_coordinator`, and `frostsnapp/rust`. That churn is the deliverable — it is what makes
the invariant hold by construction rather than by a check someone must remember.

## Acceptance

- The new type rejects `2^31` and `u32::MAX`, and accepts `2^31 - 1`.
- Encoding a valid path is byte-identical to the bare-`u32` encoding it replaces.
- Decoding a hardened index fails as a bincode decode error rather than panicking — tested not
  only on the index type in isolation but through the **enclosing wire types** that carry it
  (`AppTweak::Bitcoin`, `SignItem`, and a `WireSignTask::BitcoinTransaction` template), so a
  historical encoding with an out-of-range index is rejected wherever it can arrive.
- `from_u32_slice` rejects an account index or address index `>= 2^31` and accepts `2^31 - 1`.
- Existing tests pass; `cargo test` green and `cargo clippy` clean under `RUSTUP_TOOLCHAIN=stable`.

## Notes

- Do not change the wire byte format.
- The sign-task policy bounds (default account, `index < 200_000`) are deliberately **not** here —
  they are a separate, temporary plan. Do not anticipate them in this one.
- **No WHAT comments.** Only WHY, and only where the why is not obvious. Delete rather than trim.
- Match the surrounding style in `frostsnap_core`.
