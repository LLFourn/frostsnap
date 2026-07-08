# sim-android-tray

Make the SIM app playable on an **Android emulator** (phone form factor). The
device console, today a fixed-width panel docked beside the app, becomes a
**slide-in tray** from the right on narrow screens.

## Core model

The current tray conflates two things that are actually independent:

- **presentation** — a fixed `_trayWidth = 384` `SizedBox` docked in a hardcoded
  `Row([Expanded(app), SimDeviceTray()])` (`main.dart:276`), the tray doing its
  own `Overlay`+`Material` (`sim_device_tray.dart:106`).
- **capability** — driving the `DevicePool`. Crucially this is **in-process
  FRB**: the tray calls `device.touch()`, `device.swipe()`,
  `pool.addDevice()`, `pool.setChain()` directly (`sim_device_tray.dart:77-98`,
  `1029-1051`). It does **not** use the device unix sockets — those are only the
  *external* `./simctl` path.

On a phone the docked `Row` crushes the app to nothing. But the capability never
depended on the dock or the host: `load_sim` is plain `AF_UNIX` + FFI that
already cross-compiles for Android (cargokit, `android/app/build.gradle`
abiFilters `arm64-v8a`/`x86_64`), and the app already ships an Android target
(`main.dart:109` `Platform.isAndroid`). The only host-coupled pieces are the
**external channels** — `./simctl`'s device-channel sockets and the regtest
faucet control socket — and those are legitimately host-only.

So the change is one idea: **the SIM console is a single content surface
presented responsively over one `DevicePool`.** Split presentation from
capability:

- `SimTrayContent` — the pure console (header, faucet card, chain/disconnected
  lists; the poll/refresh + chain derivation) with **no** width / dock / Overlay
  assumptions.
- `SimTrayShell` — the responsive presenter, mounted by `main.dart`'s `builder`
  in place of the hardcoded `Row`. It picks by available width:
  - **wide** (≥ breakpoint, desktop/tablet) → the current docked side panel.
    Ergonomics unchanged.
  - **narrow** (phone) → the app is full-bleed; the console lives off-screen
    right and **slides in over a scrim** via an edge handle / drag-from-edge.

The in-process driving path is **identical on every platform**; only the shell
changes. The external `./simctl` device channels stay host-only on the emulator
(rejected; drive the chain via the tray). The regtest channels — which the
original plan also deferred — are bridged to the emulator over adb on user request
(see "Regtest bridged to the emulator"); an `--no-regtest` session still degrades
gracefully (the faucet card hides when the control socket is null,
`sim_device_tray.dart:151`).

Three structural facts to respect, not patch around:

1. **The shell sits ABOVE the app `Navigator` in BOTH modes.** Today the tray
   docks *beside* the Navigator on purpose (`main.dart:267-271`): the app's
   fullscreen dialogs render in the Navigator's own `Overlay`, so docking beside
   it keeps them from covering the tray, and the tray stays interactable while a
   dialog (e.g. the keygen Security Check) is up. The slide-in must preserve
   this invariant — it renders in the `builder` layer, over the app, **above any
   in-app dialog** — so a phone user can still drive the device mid-dialog.
2. **Capability is platform-independent; only presentation + the host channels
   are platform-specific.** Do **not** gate device-driving on platform. Gate
   *only* the external host channels.
3. **The device channels are host-only; the app channel is not — so the harness
   must split along that seam.** `SimHarness` today bundles two independent
   transports: (a) the **app channel** — the launched Flutter process +
   `FlutterDriver` over the VM service (`tap`/`waitFor`/`screenshot`/
   `requestData`, incl. `add-device` and `device-numbers`); and (b) the **device
   channels** — the host `List<SimDeviceChannel>` connected to `device-<n>.sock`
   (`SimHarness.launch` *always* calls `_connectChannel`, `sim_harness.dart:294`).
   On an emulator the `device-<n>.sock` listeners live inside the app sandbox,
   unreachable from the host, and `_connectChannel` would hang. But the app
   channel **is** reachable: `flutter run -d <emulator>` adb-forwards the Dart VM
   service and prints a host-reachable `http://127.0.0.1:PORT` URL, so
   `FlutterDriver.connect` works. The committable boundary (Task 3): factor an
   **`AppSession`** (the app-channel half — process + driver + the app-tree
   methods + `addDevice`-via-driver-data, with **no** device channels) out of
   `SimHarness`, and make `SimHarness = AppSession + the host device channels`.
   The `serve` daemon then owns an `AppSession` on Android (`platform` ≠ a host
   desktop) or a full `SimHarness` on the host — **one control socket either
   way**, so a daemon and platform state exist and `up`/`down`/forwarded commands
   work uniformly (this is *not* a bare foreground `flutter run`). Device-channel
   commands dispatched against an `AppSession` reject with **"host-only on
   Android; drive via the in-app tray"** (per the "unavailable capability must be
   reflected in the surface" rule); app-channel commands keep working over the
   forwarded VM service. Full device-channel parity over an adb→unix-socket
   bridge is an explicit **non-goal** (follow-up).

This is a Flutter-shell + launch-tooling change. No portable coordinator logic
and no `frostsnap_virtual_device` leaf is touched — the engine already runs on
Android; we only change how the console is presented and how the app is launched
on an emulator.

## Tasks

### Task 1 — Decouple console content from its dock; responsive shell
`frostsnapp/lib/sim_device_tray.dart`, `frostsnapp/lib/main.dart`

- Extract the content built in `_SimDeviceTrayState.build` (the `Column`:
  `_TrayHeader` + faucet + chain/disconnected lists, `sim_device_tray.dart:133-204`)
  into a reusable `SimTrayContent` that owns the 250ms poll/refresh
  (`_refresh`/`_apply`/`_addDevice`/`_setConnected`) and chain derivation, but
  makes **no** width/dock assumption. Add an optional `onClose` so the slide-in
  mode can show a close affordance in the header (hidden when docked).
- Introduce `SimTrayShell({required Widget app, required DevicePool pool,
  String? regtestControlSocket})`. `main.dart`'s `builder` returns it instead of
  the hardcoded `Row` (`main.dart:272-286`). It decides form factor from
  available width (`LayoutBuilder`/`MediaQuery`, breakpoint ~900), with a debug
  override `SIM_FORCE_NARROW` (dart-define) so the slide-in can be exercised on
  the desktop host (Task 2 acceptance) without an emulator. The launch path must
  be able to *set* this define — see the `extraDartDefines` hook in Task 2.
  - wide → `Row([Expanded(app), SizedBox(width: _trayWidth, child:
    SimTrayContent(...))])` — current behavior, byte-for-byte where practical.
  - narrow → the slide-in overlay (Task 2).
- Keep an `Overlay`+`Material` wrapper around `SimTrayContent` so Material
  widgets (ink, fields, tooltips) still work outside the app Navigator in both
  modes.
- Acceptance: `./simctl up` on desktop renders the docked panel **identically**
  (self-screenshot, compare against current); device-driving from the docked
  tray still works.

### Task 2 — The slide-in tray (narrow form factor)
`frostsnapp/lib/sim_device_tray.dart` (split a `sim_tray_shell.dart` if it reads
cleaner)

Design intent (think like a designer — match the existing dark
instrument-console aesthetic: `surfaceContainerLowest`, cyan primary, status
dots, mono):

- **Edge handle**: a frosted, primary-tinted **pill** pinned vertically-centred
  on the right edge, showing the live device count + a board glyph and a subtle
  grip. `semanticLabel: 'Open simulator'` (not just a tooltip) so flutter_driver
  can open it. It reads as "pull me in".
- **Open**: tap the handle, or **drag in from the right edge**. The console
  slides in from the right over a **scrim** (Material emphasized easing ~300ms;
  scrim fades to ~0.5). Panel is ~88% width capped near `_trayWidth`, full
  height.
- **Close**: tap the scrim, **swipe right**, or a close button shown in the
  console header (slide-in mode only). Drag tracks the finger with a velocity
  fling for both open and close.
- **Layering**: the overlay renders ABOVE the app — and thus above any in-app
  dialog — preserving fact #1 (drive the device while a dialog is up) on phones.
- **Committable test hook (required first):** `SimHarness.launch` hardcodes its
  `--dart-define` list (`sim_harness.dart:242-260`) and `runScenario` has no
  passthrough, so the narrow test cannot set `SIM_FORCE_NARROW` today. Add an
  `extraDartDefines` parameter (a `Map<String,String>`) threaded
  `runScenario` → `launch` → the `flutter run` arg list. The narrow-tray
  `*_drive.dart` passes `{'SIM_FORCE_NARROW': 'true'}`, so it runs under the
  normal `./simctl test` path (which `dart run`s each `*_drive.dart`) with no new
  simctl flag.
- Acceptance: an e2e `*_drive.dart` that calls `runScenario(..., extraDartDefines:
  {'SIM_FORCE_NARROW': 'true'})` on the desktop host (so it stays host-runnable
  and deterministic — the real emulator is Task 4) proving: handle present; tray
  opens and `SimTrayContent` becomes findable; the in-tray **+** add-device works
  and the chain grows; close hides the content. Asserts enumeration via "Continue
  with N devices", not mere widget presence.

### Task 3 — Android session model + launch path (human-play)
`frostsnapp/test_driver/sim_harness.dart`, `frostsnapp/test_driver/simctl.dart`,
`simctl`, `justfile` (recipe)

The control model (answers "which process owns the Android session, how simctl
detects it, where the host-only rejection lives"):

- **Split `AppSession` out of `SimHarness`** (the seam from Core-model fact #3).
  `AppSession` owns the launched Flutter process + `FlutterDriver` + the
  app-channel methods (`tap`/`tapUntil`/`waitFor`/`enterText`/`getText`/
  `screenshot`/`requestData`, and `addDevice`/`ensureDevices` which already go
  through driver-data) — **no** `SimDeviceChannel`, so `launch` does **not** call
  `_connectChannel`. `SimHarness` *is* an `AppSession` plus the host
  `List<SimDeviceChannel>`; on a host platform `launch` builds the device
  channels exactly as today. (`load_sim` itself is unchanged — confirm it boots
  on Android, where the unix sockets bind privately inside the app sandbox; fix
  any path/permission issue only if one surfaces.)
- **One daemon, platform-aware.** `serve` records the launch `platform` and
  builds a full `SimHarness` for a host desktop or just an `AppSession` for an
  Android target. Either way it owns the **same control socket** — so `up`,
  `down`, and forwarded commands behave uniformly and Android is *not* a bare
  foreground `flutter run`. The Android target is selected by an **`--android`
  flag** on `serve`/`up` (a shared `_resolvePlatform` boots/reuses an emulator and
  returns its serial); `up` compares platform-*kind* (an emulator vs the exact
  desktop platform) so an Android daemon and a desktop request don't satisfy each
  other. (There is no separate `emulator` subcommand — `--android` keeps one
  bring-up surface.)
- **Where the rejection lives: `_dispatch`.** Partition commands into
  *app-channel* (`info`/`tap`/`screen`-of-app/`add-device`/wallet flows — served
  by the `AppSession`) and *device-channel* (`touch`/`swipe`/`hold`/`chain`/
  `set-chain`/`set-connected`/device `screen` — need a `SimDeviceChannel`). When
  the session is an `AppSession` (no device channels), a device-channel command
  returns `{ok:false, error:'host-only on Android; drive via the in-app tray'}`
  rather than hanging on `ensureDevices`/`_connectChannel`. Mark these host-only
  in `./simctl` usage text.
- **Launch defaults for human-play:** **regtest ON by default** (matching the host
  `serve`/`up`; `--no-regtest` opts into an offline session) and **human owns the
  keyboard** (`agentOwnsKeyboard:false`). The narrow shell is automatic on the
  phone form factor (no `SIM_FORCE_NARROW` needed on a real device). *(The user
  asked for regtest on the emulator, so it became the default — see "Regtest
  bridged to the emulator" below; the original plan had Android offline.)*
- **Provision-if-missing**, idempotent and clearly logged (it is a large
  download): install the `emulator` package + a system image and create the AVD
  via `sdkmanager`/`avdmanager` only when absent; reuse otherwise. After boot,
  also put the device into the state the app needs (`_provisionEmulator`,
  best-effort + idempotent): a **secure lock PIN (0000)** — Frostsnap requires a
  secure lock — left **unlocked + awake** (`stayon`), because a *locked* device
  gives the app no focused window and ANRs it on launch; and **3-button nav** so
  edge-to-edge content is exercised against the bar.
- **Build flavor:** the app declares `direct`/`playstore` product flavors, so the
  Android launch passes `--flavor direct` (else `flutter run` can't pick the APK);
  and it **omits `SIM_APP_DIR`** (a host path is meaningless in the sandbox — the
  app falls back to its app-support dir). `setSemantics` is **best-effort** (it
  throws on Android, and find-by-label is host-only, so it must not tear down a
  healthy session).

### Task 4 — Bring it up on a real emulator + verify
- Boot the emulator, install + run the sim, and self-verify with `adb exec-out
  screencap`: app renders full-bleed, the edge handle is visible, the tray
  slides in, add a device via the **+**, and keygen reaches "Continue with N
  devices". Save shots to the diagnostics dir. If the emulator download/boot is
  too slow or flaky in this environment, report that honestly rather than
  claiming green (a green-but-wrong check is worse than none).
- Document the one-command path in `./simctl` help / the sim docs.
- *Done:* a fresh AVD comes up via `./simctl up --android` to a wallet that
  **receives regtest test BTC**, with the slide-in tray + live faucet card and
  3-button nav (verified by `adb screencap`). One emulator gotcha worth recording:
  repeated incremental `flutter run` installs can corrupt the launcher-activity
  registration (`am start` → result -92, launch hangs after "Installing"); a
  `-wipe-data` cold boot clears it.

### Regtest bridged to the emulator (added on user request)
The original plan deferred this as a non-goal. The user asked for the regtest node
on the emulator, so it's delivered: the backend still runs on the **host**, and
the daemon bridges its sockets so the emulator reaches them —
- **electrs** is `adb reverse`d, so the app uses the same `127.0.0.1:port` the
  electrum URL already names (no `10.0.2.2` rewrite needed);
- the **unix faucet control socket** is proxied over an `adb reverse`d loopback
  TCP port, and `SimFaucet.connect` learns to take a `host:port` endpoint as well
  as a unix path.
The app runs regtest unaware it's remote: the emulator wallet receives test BTC and
the tray's "Test BTC" card shows the live faucet balance. The proxy is owned by the
`serve` daemon and closed on shutdown. Fund from the card or the host CLI
(`./simctl regtest fund`/`mine`).

## Non-goals
- Full `./simctl` device-channel CLI parity against an emulator (the
  `device-<n>.sock`s need an adb→unix-socket bridge) — still a follow-up; the
  chain is driven via the in-app tray, and those commands are rejected host-only.
- iOS.
