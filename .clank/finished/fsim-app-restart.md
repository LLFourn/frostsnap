# fsim-app-restart
# Restart the app in place, so tests can prove restore-from-db actually works

Every e2e today starts from a virgin database: nothing ever exercises the app's own
persistence — the path where a user closes the app and reopens it to find their
wallet, device names, and history restored from sqlite. The ask: a harness API that
kills and relaunches the app WITHOUT losing the session, so a scenario can assert the
before/after.

## The model (revised per user direction, 2026-08-15)

Terminology (user direction, 2026-08-16): the durable-state API is named
**saveState/savedState** — `saveDeviceState` / `addDeviceFromSavedState` /
`DeviceSavedState` — because "snapshot" already means a SCREEN snapshot in this
harness (`SimDevice::snapshot`, `device-screen`). Older wording below reads
"snapshot" for the same concept.

Devices are composable primitives, not pool state. A device's DURABLE state is its
flash + announced firmware digest — the NVS a physical device carries in your drawer.
Everything else the earlier draft wanted to persist is NOT durable and is deliberately
not persisted (pushing back on the prior review direction):

- **Chain order is not state.** Cabling is whatever the user plugs next session; the
  app must cope with any order, and the DB — not the chain — is what persistence is
  about. Restoring "the same chain" would be inventing permanence hardware doesn't
  have.
- **Pool cardinality is not state.** The fleet after a restart is whatever gets
  plugged in. A restarted app meeting zero devices, then devices arriving one by one,
  IS the real scenario.

So snapshots are PER-DEVICE, and they travel THROUGH the harness as data (the rpc
philosophy: compose in the test file): snapshot device → hold the bytes → restart →
add a device back FROM the snapshot. No app-dir blob layout, no `load_sim` changes,
no snapshot discovery.

## Milestone 1 — runtime device lifecycle: add, remove, and no upfront count

- Sessions stop REQUIRING a device count: `deviceCount`/`--devices` becomes optional
  sugar (N launch-time `addDevice` calls); a session may start with ZERO devices and
  build its fleet at runtime. Existing tests keep working unchanged.
- `removeDevice(n)` joins `addDevice()`: disconnect (daisy-chain semantics — its
  downstream falls off) and free the slot. Device numbers stay STABLE — a removed
  number is never reused, and every surface (FRB pool, driver verbs, harness, tray,
  COMMANDS.md) reflects removal consistently; operations on a removed device error
  clearly.
- **Numbers are session-scoped, across app generations — allocated by the POOL.**
  `AppDevice` is only a number, so a handle cached before a restart must never
  silently drive a different device after it. The allocator must live at the
  protocol level, not the harness: the tray adds devices app-side, so a harness-side
  mapping could never see those allocations and surfaces would disagree.
  `DevicePool` owns logical device numbers plus a next-number counter; EVERY writer
  (FRB, driver verbs, the tray) allocates there; removed numbers are tombstoned and
  never reused; every surface speaks logical numbers, never vector positions.
  `restartApp` reads the counter before killing the old generation and seeds the new
  generation's pool with it, so numbering stays monotonic for the whole AppSession
  lifetime. A number whose device is gone errors clearly, forever. Pinned by a test
  mixing tray-side and harness-side add/remove plus a restart: old numbers error,
  and every surface agrees on the numbering throughout.
- Rust pins: add/remove/re-add keeps numbering stable and the chain coherent; the
  app-level device list converges for every writer (tray + CLI both see removals).

## Milestone 2 — per-device snapshot, and add-from-snapshot

- `device(n).snapshot()` returns the device's durable state (serialized flash +
  firmware digest) over the driver channel. It requires the device DISCONNECTED —
  a running slot cannot hand over its flash (`power_off` is what joins the thread
  and returns it), and "unplug it, then pocket it" is the physical action anyway.
  Snapshotting a connected device errors, at every surface.
- `addDevice(snapshot: …)` spawns a device FROM a snapshot: same flash, same digest
  — and because device ids derive from seed + flash, the SAME device identity, key
  shares intact. A fresh `addDevice()` stays factory-new.
- **One device per identity.** `addDevice(snapshot: …)` REJECTS a snapshot whose
  DeviceId is already live in the pool — the physical model has one device per
  identity, and a duplicate would collide in every coordinator map keyed by it.
  Rejection is a clear error at every surface. (If an adversarial duplicate-identity
  scenario is ever wanted, that is a separately named escape hatch with defined
  coordinator-visible behavior — NOT this plan, and never the default restore
  contract.)
- Rust pins, deterministic and process-local: keygen → unplug → snapshot → remove →
  add-from-snapshot → same device id, `holds_key`, digest preserved; snapshot of a
  connected device rejected; add-from-snapshot while the same DeviceId is live
  rejected.

## Milestone 3 — `session.restartApp()`, both backends at once

The harness surface is backend-opaque (one `AppSession`), so the API cannot land
host-first; both backends ship in one milestone (the relaunch machinery is mostly
shared — android also launches through `flutter run` with the same VM-service URL
capture).

- Extract the launch-and-connect half of `AppSession.launch` so it can run against an
  EXISTING app context — host: the same `SIM_APP_DIR`; android: the SAME booted
  emulator, relaunching without data wipe or reprovision.
- **Generation-aware app lifecycle** (review finding that stands): the serve daemon
  tears the session down when the app process exits — exactly the process
  `restartApp` kills. The session's app runtime becomes generational: a restart
  marks the OLD generation's exit as expected, atomically installs and watches the
  NEW generation, an UNEXPECTED current-generation exit still shuts down as today,
  and a FAILED relaunch transitions to a terminal dead state that tears down cleanly.
  A SECOND restart while one is in flight is REJECTED — the mark-expected /
  install-new transition is single-flight, or two callers could suppress exits and
  install runtimes concurrently. Pinned by a process-independent lifecycle test
  (expected old-exit, unexpected new-exit, relaunch-failure, overlapping restart
  rejected).
- `restartApp()`: kill → relaunch into the same app context → recapture the VM
  service URL → reconnect FlutterDriver + semantics → readiness gates. The app comes
  back with ZERO devices attached (truthful); the TEST re-adds devices from the
  snapshots it took beforehand.
- E2e (`app_restart_drive.dart`): build a wallet from runtime-added devices, fund +
  confirm, unplug + snapshot each device, restart, assert the db restore (wallet
  present, balance after resync), re-add the devices from snapshots, recognized
  under their names, and a send SIGNS on-device and confirms. Green on host AND
  android before the milestone commits.
- COMMANDS.md rows + documented-methods coverage throughout.

## Out of scope

- Crash-consistency: snapshots are explicit; power-loss-during-restart is not
  modeled.
- Persisting chain order or fleet cardinality (see the model above — deliberately
  rejected).

## Constraints

- No WHAT comments; document the durable/volatile split (flash+digest vs everything
  else) at the seam.
- Enforce at every surface: snapshot-while-connected, operations on removed devices,
  restart on a dead session, a second overlapping restart — all clear errors.
- Run what CI runs: `just lint-app`, `just test-ordinary --release --all-features
  --locked`; host + android lanes green. Keep `pubspec.lock` out of commits; reap
  emulators after android validation.
