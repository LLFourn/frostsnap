# fsim-erase-identity
# fsim-erase-identity — an erased sim device must come back a stranger

## Problem (verified live 2026-08-17)

Erasing a device in the sim looks like it does nothing: the erased device
instantly reappears in the app as its old self ("SimDev1 — Wallet available for
recovery"), and the erase dialog sits on "Waiting for device reset" as if the
device never disconnected.

The erase itself is NOT the bug — all of this was verified at the leaf and live:

- Device side is correct: `DataErase` → swipe-up + 8s hold → first sector wiped
  → `EraseConfirmed` to the coordinator → all 64 NVS sectors erased →
  `Poll::ResetRequested` → the device thread reboots from the wiped flash and
  lands on the factory "Get started with Frostsnap" screen. A lockstep test
  (real keygen share, then the erase flow) confirms `holds_key == false` after
  the reboot.
- The disconnect also happens — as a millisecond blink. serve.log shows
  `Read reset downstream!` → port disconnected → device removed → the rebooted
  device re-announces on the same port and re-registers immediately.
- The root cause: **the erased device resurrects with the SAME device id**
  (verified: id_before == id_after across an erase). `VirtualDevice` seeds its
  HAL RNG with `ChaCha20Rng::seed_from_u64(seed)` on every boot
  (`tools/virtual_device/src/device.rs`), so re-initializing the wiped flash
  header draws the identical entropy and re-derives the identical keypair.
  Every id-keyed coordinator record (the device name, key associations) then
  re-attaches on re-announce — the app presents the wiped device as "SimDev1 —
  Wallet available for recovery", which reads as "still has the shares".

On real hardware the flash header is initialized from the hardware RNG, so an
erase mints a NEW device id: the coordinator sees a blank stranger and nothing
re-attaches. The per-chip keyed-hash secret (efuse analog: `SimKeyedHash` from
`seed`) survives the erase on both real and sim — that part is modeled right.

## Model

**Identity is minted at header init and lives in the flash header** — not a
function of the boot seed. Concretely:

- A boot whose flash already has a header keeps its identity (normal reboot,
  power-cycle, saveState/restore — the saved bytes carry the header).
- A boot that must INIT the header (first factory boot, or the boot after an
  erase) mints a FRESH identity: the HAL RNG must never replay a previous
  boot's stream — including a stream from a previous PROCESS. A per-process
  counter alone restarts at zero, and the coordinator's DB outlives the process
  (`restartApp`, any app relaunch), so a relaunched sim rebuilding a blank
  device from the same seed would reclaim its old id and resurrect the very
  identity this removes. The stream seed therefore mixes BOTH a process-unique
  epoch drawn from OS entropy AND an atomic per-boot counter, keyed by the
  seed-fixed `SimKeyedHash` (the efuse-analog keys stay seed-derived).
- Bonus correctness: today every reboot replays the same RNG stream (nonce
  reuse across reboots in anything drawing runtime randomness). Per-boot
  freshness fixes that latent modeling bug too.

**The slot's cached identity must follow the device across an erase.** The
router slot and the FRB `SimDevice` capture `device_id` at spawn; an in-thread
erase-reboot changes the id mid-thread, leaving those caches stale — the tray
would label the stranger with the old id, and `insert_slot`'s one-device-per-
identity guard would compare against a dead identity (wrongly rejecting the
restore of a state saved BEFORE the erase, whose identity is in fact free
again). Make the identity a live cell like `FirmwareDigestCell`: the device
thread publishes each boot's id; the router slot and handles read through it.

Consequence to embrace: fresh factory boots are no longer deterministic per
seed, so a fresh add can never collide with a restored blank device's identity.
`fresh_add_cannot_duplicate_a_restored_identity` loses its premise (that
collision is now impossible by construction — which is the point); the
uniqueness guard itself stays, still enforcing "the same saved state cannot be
restored twice while its identity is live". Audit for anything else relying on
per-seed deterministic ids (hardcoded ids, double-boot equality asserts, the
android baked-in device across launches) and adjust.

## Milestone 1 — identity dies with the header (leaf)

- Per-boot RNG entropy in the sim HAL construction: OS-random process epoch +
  atomic boot counter; efuse-analog hasher stays seed-fixed. Expose the
  (epoch, counter) derivation as a seam so a test can stand in two launches.
- Identity cell: thread publishes each boot's id; `ChainRouter::device_id`,
  `save_device_state`, `insert_slot`'s guard, and the FRB `SimDevice::id()`
  read through it.
- Leaf tests (tools/virtual_device):
  - The full erase flow as a lockstep test — real keygen share, `DataErase`,
    swipe-up + hold, `EraseConfirmed` observed, reset observed, reboot from the
    same flash: `!holds_key` AND `id_after != id_before`.
  - Power-cycle and saveState/restore still preserve identity (header carried).
  - After an erase, restoring the PRE-erase saved state succeeds (that identity
    is free again) — pins the identity-cell refresh.
  - Fresh adds mint unique identities; rework the dissolved collision test.
  - Cross-launch: blank-header init with the SAME seed in two independent
    epochs yields different ids (and each boot within a launch differs), while
    the header-carrying paths above keep theirs.
- Doc sweep: router/pool comments claiming "seed + flash derived" identity.

## Milestone 2 — the user-visible flow, end to end

New e2e `erase_device_drive` (host lane required; run the android lane once
before finishing): create a 1-of-1 wallet on device 1, then from Device
Details → Advanced → Erase: drive the device's swipe-up + 9s hold, and assert
- the erase dialog ("Waiting for device reset") DISMISSES,
- the harness sees the slot's device id CHANGE across the erase,
- the device re-announces as an UNNAMED stranger: no "SimDev1", no
  "Wallet available for recovery" card for it,
- the wallet no longer lists the erased device as a key holder.

No app (frostsnapp/lib) changes expected: with the identity fixed, the erase
dialog's "device gone" condition keys on an id that never comes back, so it
dismisses robustly even though the sim's port blink is milliseconds. If the
e2e proves otherwise, stop and surface it rather than patching the app in this
plan.

## Non-goals

- Modeling a seconds-long USB down-time on reset (real-hw enumeration delay).
- Any change to `frostsnap_embedded` (off-limits) or the app's erase UX.
- The `DeviceSavedState` codec (the header rides in the flash bytes already).
