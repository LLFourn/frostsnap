# sim-8-dual-channel-harness
# sim-8: unified two-channel sim driver harness (app + device)

## Goal
One harness that brings up the sim app + a virtual device, drives BOTH seamlessly through a single
ergonomic API, and tears EVERYTHING down as a unit — app process, device channel, the disposable app
dir, and every screenshot it captured. This replaces the OS-level pixel-hunting / window-bounds
friction hit while hand-driving a keygen with semantic targeting, and gives a reusable out-of-process
way to drive the same flow the in-isolate test drives.

## Core model (read first)
The app and the device are two DIFFERENT machines and get two DIFFERENT channels — conflating them is
the mistake that produced the friction:
- **App = a Flutter widget tree.** Drive it by **semantic label** over `flutter_driver` (the VM
  service the app already exposes). Screenshot the whole app (incl. the tray) with
  `FlutterDriver.screenshot()` — it captures the Flutter surface, so the tray is included and the
  native window chrome is not.
- **Device = a framebuffer + a touchscreen.** It has NO widget identity (Flutter only blits its
  framebuffer into a `RawImage`). Drive it through a SEPARATE channel speaking device-hardware
  semantics (tap/hold/swipe/raw down-move-up + read framebuffer + plug state). This channel MUST NOT
  go through Flutter.

One **harness** owns both channels as a single lifecycle: `setUp` launches the app on a clean
disposable dir with both channels enabled and connects to them; `tearDown` quits the app, closes both
clients, and deletes the disposable dir AND every screenshot it captured. The device-channel SERVER
lives inside the app process (started by `load_sim`), so it lives and dies with the app; the harness is
the CLIENT that orchestrates launch + connect + teardown.

Leaf-only invariant (the sim epic rule): the device channel is a sim-only transport/control leaf.
Device input feeds the EXISTING `TouchQueue` -> `FrostyUi` (portable); the socket server and the new
primitives must not re-implement any portable device logic.

## Channels

### App channel (flutter_driver)
- A dedicated `test_driver/sim_app.dart` (SIM only): `enableFlutterDriverExtension()` then runs
  `app.main()`. Keeps `flutter_driver` a dev-dependency, out of production `lib/main.dart`.
- Client: `FlutterDriver.connect(vmServiceUri)` (harness captures the URI from the launched app's
  stdout). Find/tap/enterText/waitFor by **semantic label** (`find.bySemanticsLabel`), NOT by
  `ValueKey`. The targeting hooks then double as **accessibility** metadata the app should have anyway,
  rather than test-only `ValueKey`s that are dead weight when the flow is rewritten.
- **Inline, no shared file (USER DECISION — overrides the reviewer's single-source request):** the
  controls are targeted by their natural accessible name with NO shared constants file. Most controls
  need no annotation — a button's visible `Text` already is its semantic label, so the driver targets
  `'Continue anyway'` / `'Generate keys'` / etc. inline; controls with no derivable label (the two
  text fields) get an inline `Semantics(label: '...')`. The driver references the same strings inline.
  The sim-6/7 `KeygenKeys`/`keygen_key_ids` (ValueKey-based) + the `key:`/`tappableKey:` attributes are
  removed. The harness enables the semantics tree on connect (`FlutterDriver.setSemantics(true)`).
  Accepted trade-off (explicitly chosen for simplicity/zero-files over ruthless's single-source
  request on commit 6bb54e8): the label string lives in two places (app + driver) with no single
  source, so a copy edit must be mirrored in the driver — caught by the keygen driver test failing.
- Screenshot: `FlutterDriver.screenshot()` -> PNG of the whole app incl. the tray.

### Device channel (Rust socket, SIM-only)
- A small server in `tools/virtual_device` owning the `SpawnedDevice` handles (`TouchQueue`,
  `SharedFramebuffer`, `PortConnection`), started by `load_sim` in SIM mode, bound to a unix socket
  under `SIM_APP_DIR` (e.g. `<dir>/device-0.sock`). Dies with the app process.
- Protocol: line-delimited JSON request/response. Commands:
  - `tap {x,y}`, `hold {x,y,ms}`, `swipe {x1,y1,x2,y2,ms}`.
  - `touch {x,y,lift_up}` — the raw single-event primitive. `lift_up:false` is a press/move
    (repeated at moving points = a drag), `lift_up:true` is a release; this is down/move/up.
    Directional swipe *shortcuts* (`swipeUp/Down/Left/Right`) are a **client-side** convenience over
    the generic `swipe` (the server keeps a minimal vocabulary; the harness/CLI computes the vector).
  - `screen {path}` -> `{ok:true, path}` — writes the exact device framebuffer (`SharedFramebuffer`)
    as a PNG to `path` (chosen over an inline `png_base64` body: no base64 dep, reuses `save_png`, and
    it fits the cleanup model). The **harness supplies a `<SIM_APP_DIR>/screenshots/...` path and owns
    cleanup** (teardown `rm -rf`s `SIM_APP_DIR`), so device screens are removed with everything else.
  - `set_connected {connected:bool}`, `is_connected`, `device_id`.
- Needs enriched device-input primitives on `VirtualDevice`/`SimDevice`: hold-with-duration (a latched
  touch held N ms of the device's wall-clock) and a move sequence (so swipes are possible — the
  current GUI path can't swipe; the tray `Listener` has no `onPointerMove`). These feed `TouchQueue`.

## Unified client API + CLI
- `SimHarness` (Dart): `launch()` = mktemp dir, start the app with SIM + `SIM_APP_DIR` + driver, wait
  for the VM service + the device socket, connect both. Surfaces:
  - `app`: `tap(label)`, `enterText(label, s)`, `text(label)`, `waitFor(label)`, `exists(label)`,
    `screenshot([name])` — all target by semantic label.
  - `device`: `tap/hold/swipe/touch/screen/setConnected/isConnected`, plus a **generic**
    `holdConfirm(x, y, [dur])` (hold-to-confirm is a device-wide pattern; the caller supplies the
    per-screen button point — it is NOT keygen-specific and carries no baked-in coords).
  - `screenshot([name])`: whole-app PNG via the driver.
  - `tearDown()`: quit app, close clients, `rm -rf` the temp dir (incl. all screenshots).
- `runScenario(name, body)`: launch -> run `body(h)` -> tearDown; on failure dump diagnostics
  (whole-app screenshot + device framebuffer + error + recent app logs to
  `build/sim-failures/<name>/`); on success assert no residue. The keygen test uses this.

### simctl: one set of calls, persistent session (no drift)
The interactive CLI and the tests MUST drive through the SAME calls (the `SimHarness` methods) — no
second implementation that can drift. And interactive use must be **progressive against a live app**:
send a command, see the result, try the next — the app must NOT relaunch between attempts (a relaunch
is a ~1min build), so a failed attempt is followed by another command on the same running app.
- `simctl serve`: launches `SimHarness` ONCE (app + device stay alive) and listens on a control
  socket, **forwarding** each command to the matching `SimHarness` method. A thin name->method
  dispatcher — it reimplements nothing, so there is nothing to drift; a new capability is one new
  `SimHarness` method + one dispatch case.
- `simctl <cmd>` (client): connects to the running daemon, runs ONE `SimHarness` call, prints the
  result, exits — the app persists across invocations. Commands: `tap`/`tap-until`/`enter`/`wait`
  (app, by semantic label; `--regex` for substring), `hold`/`swipe`/`touch`/`screen`/`set-connected`
  (device), `shot` (whole-app screenshot), `down` (tearDown + exit).
- So the keygen test (`runScenario` calling `SimHarness` methods) and the live agent (`simctl`
  forwarding to the same methods) share one driving surface. Dart for the harness + CLI
  (flutter_driver is Dart-native); the device SERVER stays Rust.

## Screenshot lifecycle (explicit requirement)
- Harness-captured screenshots default to `<SIM_APP_DIR>/screenshots/<NNN>-<name>.png`. `tearDown()`
  removes the whole `SIM_APP_DIR`, so screenshots are cleaned up with everything else — no orphans.
- To deliberately KEEP a shot, pass an explicit out-of-tree path; only then does it survive teardown.

## Flow gaps to fold in (found hand-driving a keygen)
1. `SIM_APP_DIR` dart-define (clean DB per run) — make it first-class. Without it a persisted wallet
   hides the create entry at launch (the `keygen_test.dart` step-1 failure).
2. A targetable **semantic label** on the "Only one device -> Continue anyway" confirm dialog button
   (appears for a 1-device keygen; not driveable today, would stall the automated test).
3. The post-keygen "Unplug devices to continue" step REQUIRES a disconnect -> harness/test drives
   `device.setConnected(false)` to finish.

## Tasks
1. Device-input primitives: hold-with-duration + move/swipe on `VirtualDevice`/`SimDevice` feeding
   `TouchQueue`, leaf-only.
2. Device channel server (Rust, `tools/virtual_device`): unix-socket JSON protocol; started by
   `load_sim` under `SIM_APP_DIR`; torn down with the process. `SIM_APP_DIR` dart-define first-class.
3. App channel: a `test_driver/sim_app.dart` entrypoint calling `enableFlutterDriverExtension` in SIM
   mode (SIM-only; keeps `flutter_driver` a dev dep out of `lib/main.dart`).
4. `SimHarness` (Dart) + `simctl` CLI: launch/connect/teardown both channels; target the app by
   semantic label; driver screenshot; managed-screenshot dir under `SIM_APP_DIR`, cleaned on teardown.
5. Semantic-label targeting, INLINE (no shared file — user decision): remove the sim-6/7
   `KeygenKeys`/`keygen_key_ids` + the `key:`/`tappableKey:` attributes. Buttons need no annotation
   (visible text == semantic label); the two text fields get an inline `Semantics(label: '...')`.
   The driver references the label strings inline. Confirm the unplug step is drivable.
6. Add a driver-based keygen test (`test_driver/keygen_drive.dart`) on the harness: clean dir, full
   keygen incl. the dialog + the unplug-to-finish, asserting a finalized 1-of-1 wallet. Add a `just`
   recipe. Remove the now-superseded sim-7 in-isolate `keygen_test.dart` + its `sim-keygen-test`
   recipe (it depends on the removed `KeygenKeys`).

## Acceptance
- `cargo test -p frostsnap_virtual_device` green, incl. a device-channel round-trip test
  (tap/hold/swipe/screen/set_connected over the socket) and the new input primitives.
- `cargo check -p rust_lib_frostsnapp` builds; `flutter analyze` clean; `dart format` clean (incl.
  `integration_test` + the harness/CLI); esp unaffected; production `load()`/`main.dart` unchanged.
- A documented end-to-end run where `SimHarness`/`simctl` drives the full keygen on a clean dir and
  tears everything down — assert the temp dir (and thus all screenshots) is GONE afterward, no
  residue. The live GUI run stays the user/CI step; disk-observable artifacts are the reviewers' gate.

## Depends on
sim-7 (the sim app + tray + connect/disconnect). Replaces sim-7's `KeygenKeys` targeting with
semantic labels. Reuses sim-3's calibrated device confirm coords (passed by the keygen driver into
the generic `device.holdConfirm(x, y)`).
