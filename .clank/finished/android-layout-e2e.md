# android-layout-e2e

Catch the backup-sheet safe-area bug with a test that **runs through the Android
emulator** and fails because the "Show secret backup" button renders behind the
system navigation bar — then fix it. Getting there means filling the tooling gaps
that make emulator e2es hard today, including **factoring the open-coded flows
(keygen, device backup) into reusable functions**.

## Core model

Today a sim scenario is **host-bound and open-coded**:

- `runScenario` only ever builds a host `SimHarness`
  (`sim_harness.dart:178`) — there is no way to run a scenario *on the emulator*.
- Driving a device goes through the host unix socket
  (`h.device(n).holdConfirm`, `sim_harness.dart`), which an `AppSession` (the
  Android session) **rejects as host-only** — so no flow that touches a device
  can run on the emulator.
- `setSemantics` throws on Android (best-effort skipped,
  `sim_harness.dart:288`), so `find`/`tap`/geometry don't work there yet.
- Flows like keygen are **hand-coded inside one `*_drive.dart`**
  (`keygen_drive.dart:31-56`) — nothing is reusable, so every new test re-derives
  the whole sequence.
- There is no assertion for "a widget is occluded by a system inset" — the exact
  thing this bug is.

The missing model is one idea: **a scenario is platform-agnostic, driven entirely
over the app channel, and composed from reusable flow functions.** The device is
driven the SAME way on host and emulator (app channel → the FRB `simDevicePool`),
not over a host-only socket; flows (`createWallet`, `openDeviceBackup`) are
functions any test calls; and a scenario can target the emulator. With that, the
safe-area test is ~5 lines, and the bug it catches is real.

This is **sim test-infrastructure + one app bug fix**. No portable coordinator
logic or `frostsnap_virtual_device` leaf changes; the app fix is a one-widget
safe-area inset.

Structural facts to respect, not patch around:

1. **Device driving must move to the app channel to be platform-agnostic.** The
   host `SimDeviceChannel` sockets are unreachable from an emulator host, but the
   FRB `simDevicePool` lives *in the app* and is reachable over the (adb-forwarded)
   VM service via driver-data. So device gestures for *flows* go through
   driver-data → `simDevicePool`, which works identically on host and emulator.
   The host sockets stay — but only as the `./simctl` external-CLI path, not the
   flow path. (Not pixel-tapping the tray: this drives the pool directly, the same
   object the tray drives.)
2. **The occlusion check needs the view's real insets.** The bug only manifests
   where there's a bottom inset (the emulator's 3-button nav bar; host desktop has
   none). The test gets the widget's screen rect from `flutter_driver` geometry
   (`getBottomRight`) and the inset from a `metrics` driver-data endpoint
   (`FlutterView.viewPadding` / `MediaQuery`), and asserts the widget sits above
   `height - bottomInset`.
3. **Refactoring flows must not change host behaviour.** `keygen_drive.dart` is
   green today; re-pointing it at the new reusable `createWallet` must leave it
   green (same steps, same asserts) — the refactor is verified by the existing
   test, not just the new one.

## Tasks

### Task 1 — App-channel device driving + Android driver readiness + view metrics
`frostsnapp/test_driver/sim_app.dart`, `frostsnapp/test_driver/sim_harness.dart`

- **`setSemantics` works on Android:** retry it (short backoff) until the root
  widget is attached (the assertion is a runApp-timing race), so `find`/`tap`/
  `getBottomRight` resolve on the emulator. Falls back to a logged skip only if it
  never attaches.
- **Device driving over driver-data → `simDevicePool`:** add endpoints that drive
  the pool in-process — `device-hold:N:x:y:ms` (touch-down → wait ms → touch-up,
  since `SimDevice` has `touch`/`swipe` but no `hold`), `device-touch`,
  `device-swipe`, `device-connect:N`/`device-disconnect:N`. They work on host AND
  emulator. Put the harness-facing methods on **`AppSession`** (so both
  `SimHarness` and the emulator `AppSession` have them): `holdConfirm(n,…)`,
  `swipeDevice(n,…)`, `connectDevice(n)`, etc., routed through driver-data.
- **`metrics` endpoint:** returns JSON `{width,height,bottomInset,topInset}` in
  logical pixels from the app's `FlutterView` (`view.physicalSize /
  devicePixelRatio`, `view.viewPadding/devicePixelRatio`), for the occlusion
  assertion.
- Acceptance: on the host, `holdConfirm` via the app channel drives a device
  (drop-in for the socket path); `metrics` returns sane numbers.

### Task 2 — Reusable flows + an emulator scenario runner + occlusion assertion
`frostsnapp/test_driver/sim_harness.dart` (or a new `flows.dart`),
`frostsnapp/test_driver/simctl.dart`, `frostsnapp/test_driver/keygen_drive.dart`

- **Factor flows into functions** on `AppSession` (so they run on host + emulator):
  `createWallet({name, deviceCount})` (create → name devices → generate at the
  **recommended threshold** → security-check hold-confirm each device using Task
  1's app-channel `holdConfirm` → unplug-to-finalize) and `openDeviceBackup()`
  (from a wallet → Backup keys → connect a device → the "Record backup
  information" sheet). A *custom* threshold (driving the keygen threshold slider)
  is a follow-up — not needed for the safe-area test (1-of-1) and out of scope
  here. **Re-point `keygen_drive.dart` at `createWallet`** — it must stay green
  (the refactor's proof).
- **Emulator scenario runner:** `AppSession.runScenario(name, body, …)` runs the
  body against an **`AppSession`** (no host device channels) targeting
  `SIM_FLUTTER_DEVICE` (default macos). `./simctl test <name> --android` boots/
  reuses the emulator (reuse the `up --android` path), clears the app for fresh
  state, and sets that env. Host `SimHarness.runScenario` is unchanged.
- **Occlusion assertion:** `expectAboveBottomInset(Pattern label)` on `AppSession`
  — a widget's `getBottomRight` vs `metrics.height - metrics.bottomInset`; throws a
  clear "occluded by the N px bottom inset" error. The widget's geometry is read
  via a small **settle helper** (`_settledBottomRight`: sample until two reads
  agree) rather than a synchronized/`pumpAndSettle` read, because **this app never
  reaches frame-idle** — a perpetual UI animation (the spinning sync icon while the
  wallet syncs, indeterminate progress loaders) is almost always on screen, so
  flutter_driver's frame-sync just times out. An explicit "wait until it stops
  moving" is the correct out-of-process pattern here (cf. Appium/Playwright), not a
  hack — there is no settled frame to sync on.

### Task 3 — The safe-area e2e (red) → fix (green)
`frostsnapp/test_driver/android_safe_area_drive.dart` (new), `frostsnapp/lib/theme.dart`

- **The test:** `AppSession.runScenario('android-safe-area', (h) async { … })` →
  `createWallet(...)` → `openDeviceBackup()` → open "Record backup information" →
  `expectAboveBottomInset('Show secret backup')`. Run:
  `./simctl test android_safe_area --android` (which targets the emulator via
  `SIM_FLUTTER_DEVICE`). It **FAILS first** (the button's settled bottom is below
  `height - navBarInset`, ~898 vs 866).
- **The fix is the SHARED sheet helper, not the one screen.** The action bar isn't
  occluded by anything specific to backup: `showBottomSheetOrDialog` (`theme.dart`,
  used by ~17 sheets) shows a `showModalBottomSheet(useSafeArea: true)`, and
  `useSafeArea` deliberately leaves the BOTTOM flush to the screen — so EVERY
  sheet's content sits behind the nav bar. Fix the class at the helper: wrap the
  bottom-sheet content in the complementary `SafeArea(top/left/right: false)` so the
  bottom inset is applied (consumption-aware → no double with `useSafeArea`'s
  `SafeArea(bottom: false)`; a no-op on desktop where there's no inset, and desktop
  uses the dialog branch anyway).
- **Verify:** the new e2e passes (green) on the emulator; `./simctl test keygen`
  (host) still passes (the shared `theme.dart` change doesn't regress desktop).

## Non-goals
- Full `./simctl` device-channel CLI parity on the emulator (the *sockets* stay
  host-only; this adds an *app-channel* driving path for FLOWS, not the CLI).
- A general golden/pixel-diff framework — this is one targeted occlusion assertion.
- Auditing every app screen for safe-area bugs — fix the backup bar (+ its shared
  widget if any); a broader sweep is a follow-up.
