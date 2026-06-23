# sim-tray-swipe-gesture
# Swipe UP/DOWN on a virtual device by dragging it in the tray (the CLI path already works)

## Goal
Let a vertical drag (swipe UP / swipe DOWN) on a connected device's live screen in the sim tray
register as a real swipe — the gesture the device UI uses to scroll/advance screens — matching what
`./simctl swipe` already does from the CLI.

## Why (the two injection paths differ)
The firmware's portable touch handler (`frostsnap_embedded/src/touch_handler.rs`) only runs
`handle_vertical_drag` when `TouchEvent.gesture` is `SlideUp`/`SlideDown`; the hardware reports it
and the host/sim must synthesize it. There are TWO sim injection paths:
- **Device channel / CLI (already correct):** `./simctl swipe` → `simctl.dart` →
  `SimDeviceChannel.swipe` → `tools/virtual_device/src/channel.rs` → `DeviceInput::swipe`
  (`tools/virtual_device/src/input.rs`), which `infer_gesture`s the dominant direction and tags
  every event `SlideUp`/`SlideDown`/`SlideLeft`/`SlideRight`. CLI swipes work today.
- **Tray / FRB (the gap):** `frostsnapp/rust/src/api/sim.rs` `SimDevice::touch` pushes a single
  `TouchEvent` with `gesture: TouchGesture::None`, and there is no FRB swipe. So a tray mouse-drag
  can only tap — vertical swipe-up/down does nothing.

## Scope
- `frostsnapp/rust/src/api/sim.rs` — add a gesture-aware `SimDevice::swipe` that delegates to the
  EXISTING `DeviceInput` (`DeviceInput::new(self.touch.clone()).swipe(...)`), so `infer_gesture`
  stays the single source of truth (no duplicated gesture logic).
- `frostsnapp/lib/sim_device_tray.dart` — the tray `_DeviceScreen`: turn a vertical mouse drag into
  one `SimDevice.swipe(start → end)` call; a tap (no movement) stays `touch`.
- LEAF-ONLY: `frostsnap_embedded`/esp and the device-channel/CLI path are UNCHANGED; we reuse
  `DeviceInput`/`infer_gesture`, not modify them. (Touch `input.rs`/`channel.rs` only if adding
  shared-helper regression coverage.)

## Tasks
1. **FRB swipe.** Add `SimDevice::swipe(x1, y1, x2, y2[, ms])` in `rust/api/sim.rs` that runs the
   drag through `DeviceInput::swipe` (the same gesture-inferring path the device channel uses), so
   SlideUp/SlideDown are synthesized for the FRB/tray path too. `touch` (tap/hold) is unchanged.
2. **Tray drag.** In `_DeviceScreen`, track the pointer-down point and, on pointer-up after a
   vertical move past a small threshold, call `device.swipe(downPoint → upPoint)`; otherwise emit a
   plain tap as today (so taps and hold-to-confirm are unaffected).

## Acceptance
- Dragging up/down on a connected device's tray screen scrolls/advances a swipe-driven device
  screen; `./simctl swipe <x1> <y1> <x2> <y2>` (up and down) still does the same. BOTH verified.
- Tap and hold-to-confirm behave exactly as before.
- Leaf-only: `frostsnap_embedded`/esp/firmware untouched; `infer_gesture` reused (one source);
  analyze + format + cargo green; no orphans.

## Depends on
The sim device tray (sim-12/13, sim-tray-redesign) and the virtual-device touch primitive (sim-1).
