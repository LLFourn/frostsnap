# fsim-firmware-upgrade
# Simulated firmware upgrades: the full upgrade UX, protocol-faithful, storage-free

The firmware-upgrade flow — the app detecting a stale device, the user consenting on both
sides, the chunked transfer with its progress UI, the device reboot, the up-to-date
re-announce — has zero automated coverage and is currently testable only with hardware.

## Direction and fidelity — REVISED (user decision, 2026-08-13)

The original direction (virtual OTA partitions + the hoisted machinery + boot hashing the
active slot) was implemented far enough to price it: making `SimFirmware` borrow real
flash partitions forces the slot flash out of `VirtualDevice` and a lifetime
(`VirtualDevice<'f>`, `SimHal<'f>`, …) through the sim's core plumbing, plus
panic-as-power-loss machinery in the serial leaf. That reshapes the sim's spine for
storage fidelity the stated goal — testing the UX — never observes. The user called it
off; this plan now targets **protocol-and-UI fidelity, not storage fidelity**:

- **Real, unchanged**: every comms message (`PrepareUpgrade*`, `AckUpgradeMode`,
  `EnterUpgradeMode`, the raw byte stream with its chunk-ready flow control, daisy-chain
  passive forwarding), the whole coordinator side (`firmware_upgrade.rs`, `FirmwareBin`),
  the app UX, and every device screen — the consent prompt and erase/download progress
  are the real shared widgets driven through the real `Workflow` values.
- **Faked, knowingly**: the device stores nothing and verifies nothing. It drains the
  real byte stream (someone must — the coordinator genuinely sends it) but discards the
  bytes, then trusts the coordinator's claimed digest and announces it after reboot. No
  partitions, no hashing, no otadata.
- **Milestone 1 is REVERTED (user decision, 2026-08-13 — see Milestone 4).** The hoist
  existed to let the sim substitute a flash; the pivot removed that consumer before it
  ever appeared, and the "keeps the door open / improves readability" justification did
  not survive scrutiny against what the move actually did to the esp path.

**On the earlier "no sidecar" review finding**: the gate correctly rejected a sim-side
digest record *next to* real OTA partitions — two sources of truth with a non-atomic
write window. That objection dissolves here because there are no partitions: the slot's
stored digest IS the only firmware-identity record, so nothing exists for it to diverge
from. The trade is stated plainly above instead of hidden in mechanism.

## Deliberately out of scope

- **Storage fidelity**: otadata bookkeeping, image persistence, digest verification, and
  the verify-before-switch invariant never execute in the sim. A coordinator streaming
  wrong bytes would be accepted — invisible at the UI level this plan tests, real at the
  protocol-audit level it doesn't.
- **Inter-device link death.** The coordinator PORT's death IS modeled (below), but the
  device-to-device links have no equivalent: pulling the TAIL mid-BYTE-STREAM leaves the
  head's passive pump waiting forever on a downstream chunk-ready signal — exactly as
  real hardware does over its UART links, so there is nothing truer to model. The
  mid-transfer e2e therefore pulls the HEAD (the whole chain dies, through the modeled
  port); tail-pull mid-stream stays uncovered.
- **Version-matrix / downgrade-block testing** (minting images at chosen versions).
- **Genuine-check / `Challenge` signing** — the sim keeps answering `None`.
- **New-firmware behavior.** After an upgrade the device reports the new digest but runs
  the compiled-in build. Tests assert messages, screens, and announced digests — NEVER
  post-upgrade behavior.
- **Real signed images.**

## Milestone 2 — the RAM upgrade state machine + the reboot that reports it

`tools/virtual_device/src/firmware.rs` grows from the no-op into a small in-RAM state
machine mirroring the real `FirmwareUpgradeMode` shape (waiting-confirm → erase →
transfer), emitting the same `Workflow`s at the same transitions:

- `PrepareUpgrade*` with a digest ≠ the announced one → stage {size, digest} and show
  the real `Prompt::ConfirmFirmwareUpgrade`; equal digests → the real `Passive` ack
  path (chain neighbours). `upgrades_offered` keeps counting offers.
- `confirm_upgrade` → walk `FirmwareUpgradeStatus::Erase` progress across a few `poll`s
  (visible on the real widget) → `AckUpgradeMode`.
- `EnterUpgradeMode` → drain exactly `size` bytes from the raw upstream with the real
  `FIRMWARE_NEXT_CHUNK_READY_SIGNAL` flow control, forwarding downstream when a child
  exists (the passive-forward path chains for free), updating the real `Download`
  progress — discarding the bytes. Because this loop is sim-owned it checks the thread
  stop flag each iteration: power-off cancels cleanly mid-transfer with NO kill/panic
  machinery, and the RAM staging dying with the thread IS the interrupted-upgrade
  semantics (old digest on reboot). Then `ResetRequested` with the new digest recorded
  as the thread's parting word.
- **Reboot reports the result**: the device thread's exit hands the slot an optional
  "upgraded to X"; `DeviceSlot.digest` updates and — fixing a real pre-existing gap —
  `Poll::ResetRequested` now respawns the device from the same flash instead of leaving
  a dead thread in a slot that claims to be powered. The respawned boot announces the
  updated digest.

Deterministic virtual-device tests: (1) offer → consent → erase → transfer → reset →
respawned device announces the new digest; (2) power-off mid-transfer returns promptly
(no deadlock), the reboot announces the OLD digest, and a retried upgrade completes.
The Slice-0 `upgrades_offered` pin is updated deliberately: offers now legitimately
occur for stale devices; the assertion becomes "an up-to-date device is never offered".

## Milestone 3 — harness surface and the e2e

- **Opened-port death** (added in review — the transport invariant the mid-transfer
  interruption needs): a `VirtualPort` retains its `PortConnection`, and once the
  connection goes down the port's I/O fails with `BrokenPipe` — both halves of a real
  USB unplug, where before only `available_ports` reflected it. This is load-bearing
  for interruption: the coordinator's raw transfer loop holds no poll loop, so the I/O
  error is its only exit. The chain router keeps the port down while the chain is
  empty (the port models the head's cable — a timer must not revive a port with
  nothing behind it). Pinned by a focused transport test, a raw-loop-errors-promptly
  test, and a router test that an emptied chain never reconnects the port.
- Sim image sized for a real progress bar: the bytes really stream, so
  `SIM_FIRMWARE_IMAGE` grows from 64 bytes to enough chunks
  (`FirmwareBin::num_chunks`) that the app's transfer UI visibly animates, still fast
  for CI.
- Harness/fsim verbs: spawn-a-stale-device (per-device digest at spawn — the existing
  `DeviceSpec.digest` plumbing already carries it; a `--stale-firmware` style flag on
  `addDevice`), plus COMMANDS.md rows + documented-methods coverage for any new public
  surface.
- The e2e (`firmware_upgrade_drive.dart`): stale device connects → app surfaces the
  upgrade affordance → drive the app-side flow → device shows the real consent screen,
  hold-to-confirm → transfer progress visible in the app → device reboots →
  re-announces the bundled digest → app shows up-to-date. Plus two interruption cases:
  an abort at the consent stage ('Upgrade Aborted' — the protocol's own cancellation),
  and a HEAD unplug mid-transfer ('Upgrade Failed' — the raw stream dies through the
  modeled port death); after each, reconnect → old digest still announced → the flow
  re-runs to completion. Host and android lanes green.

## Milestone 4 — revert the Milestone 1 hoist (keep everything the sim actually uses)

The plan was briefly finalized with the hoist in place; the user caught what review did
not, and the plan is reopened to take the hoist back out. Four findings, each verified
on disk:

- **The consumer never arrived.** The hoist's sole purpose was the cancelled
  full-fidelity direction (the sim borrowing real `FlashPartition`s). After the pivot
  the sim imports NOTHING from `frostsnap_embedded::ota` — grep finds comments only —
  so the module has exactly one caller, `device/`, the same one it had before the move.
  A cross-crate seam with one consumer is indirection with no payer.
- **The move was not behavior-preserving.** The hoisted esp caller runs
  `secure_boot::verify_secure_boot(...).unwrap()` BEFORE the digest comparison; the
  original checks the coordinator-promised digest FIRST and panics with a diagnostic
  got/expected message. The failure path of a hardware wallet's firmware updater was
  reordered — and fronted with a bare parse/verify panic — for a consumer that does
  not exist.
- **It sits on an unmerged fix.** `firmware-downgrade-block` carries `fbd8faed`
  ("Erase the whole OTA partition before download", Nick's #534 find) against
  `device/src/ota.rs` — the file the hoist moved AND rewrote. That is exactly how a
  one-line erase-loop fix quietly fails to land in the updater.
- **The hoisted docs lie about the sim.** They claim the sim hashes with `sha2` and
  that verify-before-switch "cannot fork between the esp and sim halves" — both false
  of the shipped sim, which consumes none of this and trusts the coordinator's digest.

What reverts (restore `device/` + `frostsnap_embedded/` to their pre-plan state,
verbatim from the squash parent):

- `device/src/ota.rs` restored (original ordering, original docs, original erase loop —
  `fbd8faed` must apply cleanly again); `device/src/firmware.rs`,
  `device/src/partitions.rs`, `device/src/resources.rs`, `device/src/lib.rs` restored.
- `frostsnap_embedded/src/ota.rs` deleted; its `lib.rs` export and the `crc` dependency
  dropped (no other users in the crate).

What stays:

- Everything the sim actually uses: Milestones 2–3 in full (the RAM state machine, the
  reboot-in-thread fix, opened-port death, the harness surface, both e2e lanes).
- The `frostsnap_embedded/src/device_hal.rs` `FirmwareServices` doc update — it
  describes the sim accurately and is independent of the hoist.
- `tools/virtual_device/src/firmware.rs`'s two comment references re-point from
  `frostsnap_embedded::ota` to `device/src/ota.rs`.

Acceptance: `just check-device` green; `just test-ordinary --release --all-features
--locked` green; no `frostsnap_embedded::ota` references remain anywhere;
`git cherry-pick --no-commit fbd8faed` applies cleanly to the restored
`device/src/ota.rs` (then aborted — proving the merge hazard is gone).

## Constraints

- **No WHAT comments.** Only WHY, and only when the why isn't obvious.
- **The fidelity trade is documented at the seam**: `SimFirmware`'s module doc must say
  exactly what is faked (no storage, no verification, trusted digest) so nobody reads
  sim green as storage-path coverage. This replaces the leaf-only invariant for this
  plan — the sim-side state machine is a KNOWING duplicate of the real protocol shape,
  accepted by the user for its 3x-smaller footprint; drift is caught by the typechecked
  comms layer and the e2e driving the real coordinator against it.
- **Prefer no test to a mocked one** still applies to everything else: the messages, the
  screens, and the byte stream are real or the test is worthless.
- Run what CI runs before claiming green: `just lint-app`, `just test-ordinary --release
  --all-features --locked`; `just check-device` still proves the esp half (milestones 1
  and 4 touch it; the sim milestones must not).
- Keep `pubspec.lock` out of commits unless a dependency genuinely changed.
