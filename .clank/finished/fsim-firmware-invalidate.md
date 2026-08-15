# fsim-firmware-invalidate
# A device's firmware digest is a settable property: the next announce reports it

`fsim-firmware-upgrade` made staleness a SPAWN-time-only choice (`addDevice(
staleFirmware: true)`). That cannot express the interesting case: take an EXISTING
device — keys, name, wallet state — invalidate its firmware, and force the app to
offer (and run) the upgrade on it. User decision: drop the spawn-time flag entirely
and make the digest settable at any time, with one rule — **the next time the device
announces, it reports whatever digest was last set.**

## Design — one shared cell, several writers

Today the digest is copied around: `SlotSpec.digest` → `DeviceSlot.digest` →
`SimFirmware.digest` at spawn, then handed BACK on power-off (`DeviceThread::power_off
-> (RamFlash, Sha256Digest)`) so a completed upgrade's result survives. A setter bolted
onto that shape would race the hand-back (set while running → power_off clobbers it
with the thread's stale copy).

Instead the digest becomes ONE shared per-device cell — "what the flash claims" —
owned by the slot and cloned into each spawned thread:

- `SimFirmware` READS it live: the announce, and the Passive-vs-Upgrading decision on
  `PrepareUpgrade*`, both see the current value. No reboot required for the semantic —
  an announce happens on every (re-)handshake, so unplug/replug is how a test makes
  the coordinator re-read it.
- A COMPLETED transfer WRITES it (interrupted transfers still write nothing — the
  old digest survives power loss exactly as today).
- The new setter WRITES it, any time, powered or not. Last writer wins.
- **Net deletion**: the `upgraded_to` handover, the digest half of
  `DeviceThread::power_off`'s return, and the `power_off` → `DeviceSlot.digest`
  write-back all collapse into the cell. The thread respawn loop and the slot just
  read it.

## Surface

- Router: `ChainRouter::set_firmware_digest(index, Sha256Digest)` — infallible.
- FRB: `SimDevice.set_firmware_digest(digest_hex: String)` (64 hex chars, error
  otherwise). No stale/fresh convenience — the caller says exactly what the device
  should claim; the bundled digest is what a factory-fresh `addDevice()` starts with.
- Driver/harness/eval: device-scoped `.setFirmwareDigest(hex)` following the
  `.setConnected` precedent, COMMANDS.md row, documented-methods coverage.
- **Removed**: `add_device_with_firmware(stale)`, `addDevice({staleFirmware})`, the
  `add-device-stale` verb, and their COMMANDS.md row. `addDevice()` always spawns
  factory-fresh.

## Tests

- Rust: register a device announcing the bundled digest → set a junk digest (while
  RUNNING — the harder half of the semantic) → unplug/replug → the coordinator sees
  the junk digest announced (`firmware_digest_for_device`) and offers the upgrade;
  the upgrade completes and the next announce reports the bundled digest again
  (completed-transfer writer). Existing interrupted-transfer pins keep proving the
  old-digest-survives half.
- E2e (`firmware_upgrade_drive.dart` reworked to the new surface): `addDevice()`
  fresh → no affordance → `setFirmwareDigest(junk)` → unplug/replug → 'Upgrade 1
  device' appears for a device that kept its identity → the existing
  interruption/retry/success legs run from there. Host and android lanes green.

## Milestone 2 — the device screen animates through the transfer (user-directed, 2026-08-13)

Found while reviewing the upgrade UX: the device-side Download progress WIDGET is
driven correctly (the drain sets the real `FirmwareUpgradeStatus::Download` and calls
`ui.poll()` per sector, rendering into the framebuffer), but the human-facing tray
shows a FROZEN frame for the whole transfer. Rendering and exporting are two steps in
the sim: frames reach the tray only via the device thread loop's
`take_dirty → export → on_frame` pump — and during the takeover drain that loop is
blocked inside `poll_once`, so nothing is exported until the drain returns, at which
point the next frame is the reboot screen. (The `device-screen` snapshot verb reads
the framebuffer directly, so harness snapshots see live progress — only the frames
STREAM starves.) On real hardware the physical screen IS the framebuffer, so it
animates; the sim must match.

Fix — move the export to where rendering happens, and delete the special-case pump:

- `DeviceSurfaces` gains the frame sink; `ObservedUi::poll` does the
  `take_dirty → export_rgba → on_frame` step itself after each inner poll. Every
  `ui.poll()` from ANYWHERE — the normal loop, and the blocking drain's per-sector
  poll — now feeds the tray. The thread loop's export block DELETES (single export
  path; the loop keeps only stop/reset handling). `frostsnap_embedded` untouched.
- Pin: the upgrade lifecycle test counts `on_frame` deliveries across the transfer
  window (the coordinator's progress loop) — the frozen-tray regression yields ~0
  there; the fix yields one per paced sector. The e2e additionally snapshots the
  device screen twice mid-'Upgrading' and asserts the content advances (the device
  is genuinely ON the animating download screen during the transfer).

## Out of scope

- Version strings / version-matrix testing (digests remain the version identity).
- Any coordinator- or esp-side change: `device/` and non-sim `frostsnap_embedded/`
  are untouched (milestone 4's revert stands).

## Constraints

- No WHAT comments; the cell's doc states the invariant (single firmware-identity
  record, its writers, and why last-write-wins is correct), not a narration.
- Run what CI runs: `just lint-app`, `just test-ordinary --release --all-features
  --locked`; host + android e2e lanes. Keep `pubspec.lock` out of commits.
