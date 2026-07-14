# runtime-add-devices

Add virtual devices to the sim **at runtime** (a `+` button in the tray, and a
`./simctl` command), and rename the bring-up flag `--count` → `--devices`.

## Core model

Today the virtual-device fleet is **fixed at launch**. `load_sim`
(`frostsnapp/rust/src/api/init.rs:110`) reads `SIM_DEVICE_COUNT`, builds one
`SlotSpec` per device, and `ChainRouter::new`
(`tools/virtual_device/src/chain_router.rs:298`) allocates exactly that many
`slots`/`links` Vecs — never grown again. `DevicePool`
(`frostsnapp/rust/src/api/sim.rs:124`) caches a parallel `Vec<SimDevice>` +
`Vec<DeviceChannel>` built in the same pass, and the tray fetches
`pool.devices()` **once** into a one-shot future (`sim_device_tray.dart:49`).

The change is one idea: **the fleet is growable, and the `ChainRouter` remains
its single source of truth.** "Add a device" is a single atomic growth of that
source — append one `slot`+`link`, boot it — after which every surface (the
tray `+` button, `./simctl add-device`, the device list) derives the larger
fleet from the router. We never *remove* a slot (disconnect already = power off,
keeping the slot — `chain_router.rs:71`/`476`), so device **numbers stay
contiguous and append-only** and no sparse-numbering machinery is needed.

Two structural facts fall out and must be respected, not patched around:

1. **The pool — not the router — is the add surface.** Creating
   `device-<n>.sock`, the `StreamSink<SimFrame>`, and the `SimDevice` handle all
   need the app/pool layer (`app_dir`, FFI). The device-input socket
   (`channel.rs:dispatch`) only holds the `router`, which can grow its slots but
   cannot mint a socket/handle/sink. Therefore **CLI add routes through
   driver-data** (`simDevicePool` is a global reachable from `_driverData`),
   *not* through a new device-socket command. `channel.rs` is untouched. This
   mirrors the existing split: chain *reconfig* (`set_chain`) is router-only and
   lives on the socket; fleet *growth* lives in the pool/app layer.

2. **Adding then connecting reuses the existing tail-connect path.** A new
   device is created powered-off (not in the chain), then joined at the tail via
   the existing `ChainRouter::connect` (`chain_router.rs:464`). The coordinator
   enumerates it through the unchanged firmware downstream-detect — the same
   code path as connecting an already-present disconnected device. No new
   enumeration logic, and the head device keeps its coordinator session.

3. **The out-of-process `SimHarness` cache is *also* a derived view and must
   resync — not blind-append.** The harness keeps its own positional
   `List<SimDeviceChannel>` (`sim_harness.dart:142`), one per `device-<n>.sock`,
   indexed so `device(n) == devices[n-1]`. Because the tray `+` button is an
   independent writer the harness never observes, the harness cannot just append
   one channel per its *own* `addDevice()` call: if the tray adds device 2 while
   the harness still holds only `[device-1]`, a later CLI add returning `n=3`
   would land socket-3 at local index 1 and misindex `device(2)`. So the harness
   list must be reconciled against the **app-side device numbers** (the source of
   truth), connecting any missing `device-<i>.sock` in 1-based order. Numbers are
   contiguous and append-only, so an in-order "connect the missing ones" resync
   keeps `device(n) ↔ socket-n` aligned no matter which writer grew the fleet.

This is a sim-infrastructure change only (the `frostsnap_virtual_device` leaf +
the sim FRB layer + the tray). No portable coordinator logic is touched — the
coordinator just sees one more device hot-plug at the tail.

## Tasks

### Task 1 — `ChainRouter::add_device` (growable router)
`tools/virtual_device/src/chain_router.rs`

- Factor the per-`spec` slot+link construction (the body of `new`'s loop,
  `chain_router.rs:306-334` — pipes, `DeviceHandles`, boot-once-for-id) into a
  private helper used by both `new` and `add_device`.
- `pub fn add_device(&self, spec: SlotSpec) -> usize`: lock `slots` **then**
  `state` (the SAME order `set_chain` uses, `chain_router.rs:404`/`445`, so no
  deadlock), build the slot+link, **power it off** (a new device starts
  disconnected), `push` the slot to `slots` and the link to `state.links`,
  leave `state.order` unchanged, and return the new index (= old `slots.len()`).
  Holding both locks keeps the `slots.len() == links.len()` invariant atomic vs
  a concurrent `set_chain`.
- Tests (`chain_router.rs` `#[cfg(test)]`, reuse the existing
  `UsbSerialManager`/`DeviceChange` harness): `add_device` grows the count; the
  new device has a stable, distinct id; `connect(new_index)` boots it and the
  coordinator enumerates exactly one new device while the existing chain's
  devices keep running (head session intact); adding while a chain is live does
  not perturb the current order or any device's power.

### Task 2 — `DevicePool::add_device` (FRB) + `load_sim` refactor
`frostsnapp/rust/src/api/sim.rs`, `frostsnapp/rust/src/api/init.rs`

- Give `DevicePool` what it needs to mint the next device: store `seed: u64`,
  `digest`, and `app_dir: PathBuf`; make the `devices` + `_channels` caches
  interior-mutable (e.g. a single `Mutex<PoolDevices { channels, devices }>`) so
  growth is atomic.
- Factor `load_sim`'s per-device build — frame-sink + `on_frame` + `SlotSpec`
  (`init.rs:144-162`), then `device-<n>.sock` `DeviceChannel` + `SimDevice`
  (`init.rs:177-197`) — into a shared helper used by both `load_sim` and
  `DevicePool::add_device`, so there is one construction path.
- `pub fn add_device(&self) -> Result<SimDevice>`: `index` = current count;
  build the spec with `seed.wrapping_add(index)` (matches the launch seeding,
  `init.rs:157`); `router.add_device(spec)`; build the socket channel +
  `SimDevice`; push both into the cache; `router.connect(index)` to join the
  tail; return the handle.
- `devices()` returns the locked clone. A pool-level Rust test needs FFI
  `StreamSink`, so pool growth is covered by the Dart e2e (Task 4) rather than a
  unit test — call this out, don't fake it.

### Task 3 — driver-data `add-device` + tray `+` button
`frostsnapp/test_driver/sim_app.dart`, `frostsnapp/lib/sim_device_tray.dart`

- `_driverData`: handle payload `add-device` → `await simDevicePool!.addDevice()`
  → return the new `number()` as a string. (import `lib/global.dart`.)
- Tray: replace the one-shot `_devices` future (`sim_device_tray.dart:49`) with a
  list re-read inside the existing 250 ms poll, so **every** writer converges —
  the local `+` button AND a CLI driver-data add — not just the button's own
  write (cf. the single-source-of-truth invariant). Add an "Add device" `+`
  action (header, beside Plug-in-all) → `await widget.pool.addDevice()`.
- Acceptance: `./simctl add-device` makes the new device appear in the tray with
  no tray interaction (the poll re-read), connected at the chain tail.

### Task 4 — harness device-cache resync + simctl `--devices`/`add-device` + e2e
`frostsnapp/test_driver/sim_harness.dart`, `frostsnapp/test_driver/simctl.dart`,
`frostsnapp/test_driver/sim_app.dart`

The harness cache must resync from the app-side source of truth (core-model fact
3), so it stays correct even when the **tray** is the writer:

- App-side source of truth: add a driver-data endpoint `device-numbers` (in
  `_driverData`) that returns the current `simDevicePool` device numbers in order
  (e.g. CSV `"1,2,3"`). This is the authority the harness reconciles against.
- `SimHarness._ensureDevices()`: query `device-numbers`; for every number not
  already in the local channel cache, connect its `device-<n>.sock` (reuse the
  launch wait, `sim_harness.dart:294-303`) and store it **keyed/ordered by
  number** so `device(n) ↔ socket-n` cannot drift. Because numbers are contiguous
  and append-only, this is an in-order "connect the missing ones" pass.
  - Replace the fixed launch loop (`sim_harness.dart:294-303`) with this resync.
  - `addDevice()` = `requestData('add-device')` → parse the returned number →
    `_ensureDevices()` (which connects up to and including it) → return the
    number.
  - Resync before any read of the fleet that an external writer could have grown:
    the daemon (`simctl.dart` `_dispatch`) `await`s `_ensureDevices()` before
    `info`/`devices`/`count` and before every device-targeted command, so a
    tray-side add is observed before the harness reports or indexes.
- simctl: rename `--count` → `--devices` everywhere (usage `simctl.dart:29`,
  `_up:123-125`, `_serve:270-277`); **capture the launch device count** at serve
  start and report THAT as the `info`/`up` shape field (so runtime adds don't
  flip `up` idempotence), while `info` also reports the current (resynced) count
  for introspection. Add an `add-device` dispatch case → `h.addDevice()` →
  `{ok:true, device:n}`, plus its CLI-arg → request mapping (`simctl.dart:~620`).
- Grep the repo for remaining `--count` references and update them (the
  `runScenario(deviceCount:)` Dart API is unaffected; it is not the CLI flag).
- E2e (`*_drive.dart`, in-process via `runScenario`):
  1. **CLI/harness add**: start with 1 device, `addDevice()` twice, assert
     `devices.length == 3`, each added device connected **at the tail**
     (`chain`/`is_connected`), tray renders 3 (screen/exists).
  2. **Tray-then-harness add (the resync case codex flagged)**: drive the tray
     `+` button (tap its semantic label on the tray surface) to add device 2,
     then do a harness/`device(2)` op WITHOUT a prior `addDevice()` — assert the
     harness picks up the tray-added device via resync, `device(2)` talks to
     `socket-2` (not a misindexed socket), and a subsequent `addDevice()` returns
     3 and lands correctly. Real-hw faithful: every add joins the chain tail and
     enumerates — not a star.

## Acceptance

- `./simctl up --devices 1` then `./simctl add-device` (×N) grows the chain; each
  new device is connected at the tail and enumerates to the coordinator.
- The tray `+` button and `./simctl add-device` drive the **same** `DevicePool`;
  either path is reflected in the tray (poll re-read).
- `up` idempotence is unaffected by runtime adds (shape = launch device count).
- Adding a device leaves existing devices/sessions undisturbed (head keeps its
  coordinator session).
- No dangling `--count` references remain.

## Out of scope

- Removing/destroying a device (slots are append-only; disconnect = power off).
- Multiple app instances (`--apps`) — a separate future plan.
- Inserting a device at a specific chain position (add = tail; reorder via the
  existing `set_chain`).
