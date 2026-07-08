# app-channel-only-device-driving

Retire the host-only `device-<n>.sock` device-input transport and drive every virtual
device the SAME way on host and emulator: over the **app channel** (flutter_driver
`requestData` → the in-process FRB `simDevicePool`). One transport, one source of
truth — no second device API that only works on desktop, and no cache to reconcile.

## Core model

Today a virtual device has **two** transports onto the **same** `simDevicePool`:

1. the **app channel** — `requestData('device-…')` → `_driveDevice` → `simDevicePool`
   (in-process FRB). Works on host AND emulator (the VM service is adb-forwarded), and
   it's what `createWallet`/the in-app tray already use.
2. the **device channel** — `device-<n>.sock` unix sockets that `SimDeviceChannel`
   connects to from the host. **Host-only**: the sockets live in the app's private
   storage, which is unreachable from outside an emulator sandbox.

Two transports onto one pool is a dual-source-of-truth: the harness keeps a
socket-channel cache AND reconciles it against the app-side fleet (`device-numbers`)
because the tray can mutate the pool behind the socket layer's back. That reconciliation
exists ONLY because the socket layer is a second, partial view of state the app already
owns.

**The Android tray already proves the app channel is sufficient.** It drives the
complete device lifecycle — connect, disconnect, reorder the daisy chain, hold-to-sign,
render each device screen — entirely over the app channel, because on the emulator there
is no other option. So the device socket isn't a needed second layer; it's a legacy
host-only transport kept alive by a few desktop conveniences. Retire it: make the app
channel the single transport everywhere, collapse `SimHarness`'s device channels into
`AppSession`, and route all `./simctl` device commands over it (they stop being
"host-only on Android").

Structural facts to respect:

1. **Everything the socket exposes, the app already owns** — the gap is only that a few
   capabilities were never wired over driver-data. The socket adds, beyond what
   `_driveDevice` already has (`device-hold/touch/swipe/connect/disconnect`):
   `tap` (composable from touch), `is_connected`, `chain`, `set_chain`, `device_id`,
   and the framebuffer PNG (`screen`). The tray renders the device screen + shows/edits
   the chain, so all of these are reachable app-side — they just need driver-data
   endpoints. The framebuffer is the only non-trivial one (return the device's
   framebuffer bytes, e.g. base64, over the String-typed driver-data channel).
2. **This is sim-harness/tooling only — not the device firmware or the DeviceHal leaf.**
   It changes how the HARNESS reaches the existing `simDevicePool`, not the simulated
   device behaviour. No portable device logic moves; the leaf-only invariant is
   untouched.
3. **`SimHarness` vs `AppSession` was a transport split.** Once the device channel is
   gone, the only difference between them disappears — `SimHarness` (host device
   sockets) collapses into `AppSession` (app channel only). The session shape is no
   longer platform-dependent.

## Tasks (rough)

1. **Close the app-channel capability gap.** Add the socket-only endpoints to
   `_driveDevice` (sim_app.dart): `device-chain`, `device-set-chain`, `device-id`,
   `device-is-connected`, `device-tap` (or compose from touch), and `device-screen`
   (framebuffer → base64). Each delegates to the same `simDevicePool` the tray uses.
2. **Route `AppSession.device(n)` over the app channel.** Replace `SimDeviceChannel`
   calls with driver-data so `device(n).tap/hold/swipe/setConnected/chain/screen/…`
   work identically on host and emulator. Drop the socket-cache + the `device-numbers`
   reconciliation (the app-side fleet is now the only source).
3. **Collapse `SimHarness` into `AppSession`.** With no host device sockets, the two
   shapes merge; `_connectChannel`/`device-<n>.sock` wiring + the host-only launch path
   go away. `simctl serve` runs one session shape regardless of platform.
4. **Make `./simctl` device commands platform-uniform.** `_dispatch` stops rejecting
   device-channel commands on Android ("host-only") — `hold/swipe/touch/devices/chain/
   set-chain/connect/disconnect/move-up/move-down/screen` all run over the app channel
   on host AND emulator. Update `_usage`.
5. **Delete the socket server.** Remove `device-<n>.sock` creation from `load_sim`
   (Rust) and the `SimDeviceChannel` client, so there's genuinely one transport — not a
   dead socket still being opened.

## Verification

- Existing host e2e (`keygen`, `multi_device`, `add_device`, `regtest_*`) stay green
  with device driving routed over the app channel (proves no capability regressed).
- A device command that was previously host-only (e.g. `./simctl chain`,
  `./simctl screen`) now works on `--android` too.
- No `device-<n>.sock` is created (grep the sim app dir after launch); no reconciliation
  path remains.

## Non-goals

- Changing device firmware / DeviceHal / the `simDevicePool` behaviour.
- The framebuffer transport beyond what's needed for `screen` (a base64 driver-data
  blob is fine; no streaming).
