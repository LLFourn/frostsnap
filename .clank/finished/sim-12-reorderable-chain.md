# sim-12-reorderable-chain
# sim-12: dynamic, reorderable daisy chain (two-column tray)

## Goal
Make daisy-chain membership AND order a runtime choice instead of fixed at launch. Any device can be
in the chain or not, independently of the others, and the connected devices can be arbitrarily
reordered. Surface it as a two-column tray: the LEFT column is the connected chain (top-to-bottom =
coordinator -> ... -> tail), the RIGHT column is the disconnected devices; moving a device between
columns connects/disconnects it, and up/down arrows reorder it within the chain.

## Why (what sim-10 fixed too rigidly)
sim-10 wires a FIXED chain at `load_sim` time: device i's downstream is hard-wired to device i+1's
upstream, and the only control is a per-link gate. So device 2 can only ever be device 1's child — it
can't be the head, and devices can't be reordered. That's the wrong model: on real hardware you
choose which device plugs into the computer and how the rest are cabled.

## Core model (read first)
The chain is a runtime CONFIG, not static wiring: an ordered list of connected device numbers (the
LEFT column). Everything else falls out of that one list:
- A sim-only **router** owns the single coordinator port plus every device's upstream AND downstream
  byte endpoints, and a forwarding loop splices bytes along the CURRENT chain: coordinator <-> head's
  upstream, then each adjacent pair (prev.downstream <-> next.upstream). A device not in the list is
  unspliced — its upstream goes silent, the firmware drops to Standby, and the coordinator stops
  seeing it. All of this stays emergent from the UNCHANGED firmware relay (leaf-only: the router is
  just the sim's model of re-cabling).
- The chain is ALWAYS contiguous — it is exactly the LEFT list in order — so there is never a
  "connected device sitting behind a disconnected one." Therefore `connected == in the chain` and
  `screen-on == in the chain`. This one ordered list SUBSUMES sim-10's per-link `LinkGate`s, the
  `ParentLink` (Usb/Cable) split, and the cumulative reachability the tray computed.
- Every change — connect, disconnect, reorder — is the SAME operation: produce the new ordered list
  and apply it. The router re-splices and updates each device's downstream-detect flag; devices
  re-handshake over the new topology. Removing a mid-chain device simply RE-CLOSES the chain (the
  rest shift up and stay connected) — that is the decoupling the user wants (device 2 no longer
  needs device 1).

This REPLACES sim-10's fixed `load_sim` wiring + `LinkGate`-per-link + `ParentLink` + tray
reachability with: the router + a single ordered chain config as the one source of truth.

## Rust: the router (leaf only)
- New `ChainRouter` in `tools/virtual_device`: holds the coordinator host end, per-device
  upstream+downstream host ends, the current ordered `Vec` config (behind a lock), and a forwarding
  thread that shuttles bytes between spliced ends each tick. `set_chain(order)` recomputes the splice
  map and each device's `downstream_present` flag (true iff it has a successor in the chain).
  Dropping it stops the thread.
- Build each device with `pipe()` for BOTH links (device keeps the `PipeByteIo`; the router keeps the
  host ends). `spawn_chained` takes a router-updated `Arc<AtomicBool>` downstream-present instead of a
  per-link `LinkGate`.
- `load_sim`: build N devices + the router; one `VirtualSerial::single` coordinator port wired into
  the router; initial config = all devices in number order (launch still shows a full chain).
- Rust test (replaces sim-10's subtree-drop test): config [1,2,3] registers all 3 over ONE port;
  `set_chain([2])` leaves ONLY device 2 registered (proves independent connect + head reassignment);
  `set_chain([3,1])` reorders and the coordinator's registered set follows.

## FRB / DevicePool API
- `DevicePool.chain() -> List<int>` (ordered connected numbers) and `DevicePool.setChain(List<int>)` —
  the ONE mutation. `connect`/`disconnect`/`move-up`/`move-down` are computed by the caller as a new
  ordered list and applied via `setChain` (no granular per-device connection state to drift).
- `SimDevice` keeps `number()`, frames, touch. Remove per-device `set_connected`/`is_connected` and
  `ParentLink` — connection is now "is my number in `chain()`".

## Control channel + harness + simctl
- Chain config is POOL-scoped, so serve it on a pool-level control (a small pool control socket, or
  the pool handle) rather than the per-device input sockets — `chain` (read) and `set_chain` (write).
  Per-device sockets keep tap/hold/swipe/touch/screen; drop their `set_connected`.
- `SimHarness`: `chain()` / `setChain([..])`, plus `connect(n)`/`disconnect(n)`/`moveUp(n)`/
  `moveDown(n)` computed over `setChain`. `unplug(n)`/`plug(n)` become disconnect/connect (keeps
  `keygen_drive`'s post-keygen unplug working with a 1-device chain).
- `simctl`: `chain`, `set-chain N...`, `connect N`, `disconnect N`, `move-up N`, `move-down N`.

## Tray: two columns
- LEFT = the connected chain in order: each cell is Device N (live screen) + up/down arrows (reorder,
  disabled at the ends) + a disconnect action (-> RIGHT). Top of the column = the coordinator end.
- RIGHT = disconnected devices: a compact card per device (number + a connect action that appends it
  to the LEFT chain); screen off.
- Every action recomputes the ordered list and calls `setChain`; the tray re-reads `chain()` (single
  source, reactive via the existing 250ms poll). The tray likely widens / device renders shrink to
  fit two columns — exact layout is a self-verify item.
- Replaces sim-10's single column + per-device plug toggle + reachability screen-off.

## Out of scope
- Drag-and-drop reorder (up/down arrows are enough).
- Inserting a RIGHT device at a specific interior chain position (connect appends to the tail; reorder
  with the arrows afterwards).

## Tasks
1. `ChainRouter` (forwarding loop + `set_chain` + per-device downstream-present) and device
   construction via two `pipe()`s; Rust test: one-port registration, `set_chain([2])` -> only device
   2, reorder.
2. `load_sim` builds devices + router (initial full chain); FRB `DevicePool.chain()/setChain()`;
   remove `ParentLink` + per-device `set_connected`.
3. Pool control channel + `SimHarness` + `simctl` chain ops (chain/set-chain/connect/disconnect/
   move-up/move-down); `unplug`/`plug` -> disconnect/connect.
4. Tray two-column UI (LEFT ordered chain with up/down + disconnect; RIGHT disconnected with connect);
   screen-on == in chain.
5. Rewrite `multi_device_drive` to the dynamic model: full chain registers; `setChain([2])` ->
   coordinator sees only device 2 (connected independently of device 1); a reorder changes the head;
   no residue. Keep 1-device `keygen_drive` green.

## Acceptance
- `cargo test -p frostsnap_virtual_device` green incl. the router test (one port; independent connect;
  reorder).
- `cargo check -p rust_lib_frostsnapp`; `flutter analyze`; `dart-format-check-app` clean;
  `frostsnap_embedded` forwarding UNCHANGED (leaf-only); production `load()`/`main.dart` unchanged.
- `just sim-multi-drive`: full chain registers over one port; `setChain([2])` leaves only device 2
  registered (device 2 connected independently of device 1); a reorder changes which device is head;
  teardown leaves no residue.
- 1-device `keygen_drive` still green.
- Self-verified two-column tray screenshot: connected chain on the LEFT (reorder via arrows; disconnect
  -> RIGHT), disconnected on the RIGHT (connect -> LEFT), screens lit only for chain members.

## Depends on
sim-10 (the real daisy chain + firmware relay) — this generalizes its fixed wiring into a dynamic,
reorderable chain. sim-9 (fleet, numbering, harness/simctl, tray scaffolding). sim-11 (user/agent
keyboard modes — interactive tray testing).
