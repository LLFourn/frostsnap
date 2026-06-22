# sim-13-power-off-on-disconnect
# sim-13: a disconnected device is powered off (flash preserved), powered on when reconnected

## Goal
Make a disconnected device (the RIGHT column of the sim-12 tray) mimic a real powered-off device:
its virtual-device thread is OFF (not merely idling in firmware Standby), its screen is dark, but
its flash (NVS — device keypair, any persisted shares) is PRESERVED across the power cycle.
Connecting it (→ the chain) powers it back ON: a fresh boot from the preserved flash, then it joins
the chain. A device thread runs only while the device is in the chain — chain membership drives power.

## Why
sim-12 keeps every device thread running all the time; a disconnected device is just unspliced from
the bus, so the firmware drops to Standby. That is not power-off: the device is still executing
(rendering a Standby screen), not dark, and it never re-boots on reconnect. Real hardware is powered
from the chain — unplug = power off (RAM lost), replug = power on + boot from flash (NVS persists). The
sim should match, and a power-cycle on reconnect exercises the real boot/init-from-flash path every
time (loading the device keypair / shares from NVS), which a Standby device never does.

## Core model (read first)
Chain membership drives device POWER, but the per-device HANDLES are stable across power cycles:
- A device IN the chain has a running thread (powered on). A device NOT in the chain has NO thread
  (powered off): dark screen, off the bus, RAM gone.
- **A pool-owned "power slot" per device holds everything that must SURVIVE a power-cycle** — the
  persistent flash (NVS), the `TouchQueue`, the `SharedFramebuffer`, the frame sink, the
  upstream/downstream link byte-channels, and the downstream-detect flag. These are STABLE. Power-on
  builds a fresh `VirtualDevice` WIRED TO the slot's stable peripherals + flash and spawns its thread;
  power-off stops the thread (volatile RAM/UI/session gone). So the long-lived `SimDevice` and
  `DeviceChannel` hold the SLOT's handles, NOT a particular thread's — the Dart tray (frame sink) and
  the device socket (touch/framebuffer) keep driving WHATEVER thread is currently powered. This fixes
  the stale-handle trap: today `SimDevice`/`DeviceChannel` capture the first thread's handles, which a
  restart would orphan.
- Flash is PERSISTENT across cycles: the NVS backing lives in the slot (a `Send` store, NOT inside the
  thread). Power-on loads it; power-off retains the device's writes, so a persisted share survives —
  only volatile RAM is lost (a real reboot). NOTE: the device id is derived deterministically
  (seed + flash), so the rebooted device has the SAME id whether or not flash persisted — id alone
  does NOT prove persistence; a value WRITTEN to flash at runtime (a finalized share / `holds_key`)
  does.
- Off/on boundary behavior (explicit): power-off CLEARS/darkens the framebuffer and emits one blank
  frame so the tray (and `screen`) shows dark, then stops the thread. While off: `touch` is a clean
  no-op (no thread to receive), `screen` returns the dark framebuffer, `device_id` still returns the
  device's stable id. Power-on resumes: a fresh boot frame flows to the SAME frame sink and `touch`
  reaches the newly-spawned thread via the SAME `TouchQueue`.
- `set_chain` diffs membership: removed → POWER OFF (stop thread); added → POWER ON (spawn, boot from
  the preserved flash + stable peripherals). Reorder (same membership) does NOT power-cycle — devices
  stay powered; only the re-splice + coordinator re-enumerate happen (sim-12's editor-convenience line:
  staying in the chain keeps state).

Leaf-only: the boot/init/flash logic is the unchanged portable firmware; the sim only controls WHEN a
device is powered (thread lifecycle) and PRESERVES the slot (flash + peripherals) across the cycle.
esp/embedded untouched.

## Tasks
1. Per-device power slot + stable handles: lift the `TouchQueue`, `SharedFramebuffer`, frame sink, the
   link byte-channels, and a `Send` persistent flash store OUT of the per-thread `VirtualDevice` into a
   pool-owned slot. `VirtualDevice` is (re)built each power-on wired to the slot's stable peripherals +
   flash. `SimDevice`/`DeviceChannel` reference the slot, so they survive reboots. Rust test:
   power-cycle preserves flash — a value WRITTEN to flash (a finalized share / `holds_key`) survives
   off→on (the id, being seed-derivable, is stable but does NOT alone prove flash).
2. Power lifecycle in the router/pool: `set_chain` diffs membership → stop the threads of removed
   devices (power off) + spawn-from-flash the added devices (power on); reorder keeps threads running.
   Off-chain devices have no thread.
3. Off/on boundary: power-off clears/darkens the framebuffer + emits a blank frame (tray dark) then
   stops the thread; while off `touch` no-ops, `screen` returns the dark framebuffer, `device_id`
   returns the stable id; power-on resumes frames + touch through the SAME slot handles.
4. Test/e2e: after disconnect→reconnect driven through the PRE-EXISTING `SimDevice`/device-socket
   handle: the frame stream returns (a fresh boot frame), `touch` reaches the rebooted thread, AND a
   flash-written value (a `holds_key` share from a prior keygen) survived. Also assert a disconnected
   device is off: no new frames and a dark framebuffer.

## Acceptance
- `cargo test -p frostsnap_virtual_device` green incl. a power-cycle-preserves-flash test: a value
  WRITTEN to flash at runtime (a `holds_key` share) survives off→on (not just the seed-derivable id).
- A disconnected device has no running thread + a dark framebuffer (no new frames); reconnecting
  powers it on (boot from flash) and the PRE-EXISTING `SimDevice`/socket handle drives the rebooted
  thread — verified by frames returning and `touch` landing through that same handle.
- `cargo check -p rust_lib_frostsnapp`; `flutter analyze`; `dart-format-check-app` clean; esp/embedded
  UNCHANGED (leaf-only); the sim-12 reorderable chain still works; 1-device `keygen_drive` green.
- Self-verified: in the tray, moving a device to the RIGHT column makes it go dark (off); moving it
  back LEFT powers it on (boots, screen returns) and it is drivable again through the same cell.

## Depends on
sim-12 (the reorderable chain + `ChainRouter` + `set_chain` membership). This refines sim-12's
disconnect from "unspliced / Standby" into "powered off, flash preserved, power-cycle on reconnect".
