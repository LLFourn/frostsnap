# fsim-app-pixel-tap

Two new app-surface verbs, on any platform, without leaving the harness: `session.tapTooltip(t)` —
FINDER-based targeting of tooltip-only controls (FlutterDriver's `find.byTooltip`), and
`session.tapAppAt(x, y)` — an independent positional escape hatch in logical coordinates.

## Why

`session.tap(label)` is semantic-label-only and `session.device(n).tap(x,y)` taps a virtual frost
device — there is no way to target a tooltip-only control (e.g. the pencil `Tooltip('Edit device
name')`) or tap the APP by position. Driving these today means going around the harness with
`adb shell input tap` and hand-converting display→native pixel coordinates. FlutterDriver already
ships `CommonFinders.byTooltip(String)`, so tooltip targeting stays a WIDGET finder (no rect math);
the snapshot's `tooltip` field ([sim_app.dart:94]) resolves a `Pattern` to the one exact string the
finder needs. Positional tapping is a separate, rarely-needed primitive — logical coordinates, no adb,
no display-scale math.

## Scope

### Harness — `sim_harness.dart`
- `session.tapTooltip(Pattern tooltip)`: EVERY input — exact `String` included — goes through the
  same snapshot resolver: read the current tooltips, resolve the pattern to EXACTLY one, then
  `driver.tap(find.byTooltip(exact))`; zero → error listing the tooltips that ARE present; multiple
  (including a duplicated exact string) → error listing the matches (no silent first-match). One
  code path, so an unknown exact string gets the diagnostic listing, never a raw finder timeout.
  Never taps by coordinates.
- `session.tapAppAt(double x, double y)`: thin wrapper over the `tap-at` app-channel case below —
  GLOBAL LOGICAL coordinates, origin top-left of the Flutter view.
- `test_driver/COMMANDS.md`: document both verbs.

### App side — `sim_app.dart`
- ADD a `tap-at:<x>,<y>` case to the `_driverData` handler: synthesize a `PointerDownEvent` /
  `PointerUpEvent` pair dispatched via `GestureBinding.instance.handlePointerEvent`. Framework
  `PointerEvent.position` is ALREADY global logical pixels — no devicePixelRatio scaling anywhere
  (multiplying would miss on every non-1x view). Set the view's `viewId` on the events and use a
  fresh pointer id per tap (a reused id corrupts the gesture arena across calls).
- Bounds validation: reject malformed payloads, and coordinates outside
  `view.physicalSize / view.devicePixelRatio` (the view's LOGICAL size), with an error naming that
  size. No dispatch on rejection.
- If any snapshot geometry is ever consulted, it is the TRANSFORMED global-bounds field
  (`_globalSemanticBounds`), never `SemanticsData.rect` (local to its render object).

### Tests
- Pure (`frostsnapp/test/`): the Pattern→tooltip resolution (one/zero/many, error listings — with
  zero/many cases for EXACT strings too, not just regexes) and the
  `tap-at` payload parsing + logical-bounds validation, factored into a small module testable without
  a live app.
- Widget tests for the dispatch path: a tappable target at a TRANSLATED position, pumped on a view
  with a NON-1 devicePixelRatio (e.g. 2.0) — the synthesized tap at the target's global LOGICAL
  center fires its onTap (catches any resurrected DPR-scaling or local-rect mistake); a tap outside
  logical bounds is rejected without dispatch.
- e2e (`test_driver/app_tap_drive.dart`, in the suite, host AND android): drive a tooltip-only
  control end-to-end — `tapTooltip('Disconnect')` (no semantic label) → assert device 1 leaves the
  chain; unknown + ambiguous diagnostics asserted; `tapAppAt` at 'Add device''s global-bounds center
  from the snapshot → fleet grows; out-of-bounds → error. The controls are the SIM TRAY's: expanded
  inline on the wide host window, collapsed to a rail on the narrow android layout — the scenario
  opens it (`tap('Open simulator')`) when 'Add device' isn't on-stage, so ONE scenario runs on both.
  (The feedback's 'Edit device name' pencil example doesn't exist in the current tree — `rg "Edit
  device name" lib` is empty — so on-stage tooltip-only controls stand in; 'Copy node address'
  exists only with a wallet, so the fresh-app scenario uses 'Disconnect'.)

## Acceptance
- `session.tapTooltip(<tooltip-only control>)` drives it on a live session (previously required adb
  pixel math), verified by observable app state — committed as the `app_tap` suite scenario, plus
  validated interactively ('Copy node address' → clipboard, on a wallet-bearing session).
- `tapTooltip` with an unknown tooltip → error listing available tooltips; with an ambiguous pattern →
  error listing matches.
- `tapAppAt` outside the view's logical bounds → clear error, no dispatch; a tap at a translated
  control's global logical center works on a non-1x view (widget-tested).
- Works identically on host and android (logical coordinates; no adb involved).
- Unit + widget tests green; `dart analyze` clean; host suite (`fsim test`) stays green.
