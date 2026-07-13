// fsim-app-pixel-tap: the `tap-at` positional primitive, APP-side (imports Flutter — only sim_app
// uses this; the harness-side tooltip resolver lives in tooltip_resolve.dart). Coordinates are
// GLOBAL LOGICAL pixels throughout: framework `PointerEvent.position` is already logical, so there
// is no devicePixelRatio scaling anywhere.

import 'dart:ui' show Offset, Size;

import 'package:flutter/gestures.dart';

/// Parse a `tap-at:<x>,<y>` payload's argument. Returns null on malformed input — including
/// non-FINITE axes: `double.tryParse` accepts "NaN"/"Infinity", and NaN compares false against
/// every bound, so it would sail through validation into the gesture binding.
Offset? parseTapAt(String arg) {
  final parts = arg.split(',');
  if (parts.length != 2) return null;
  final x = double.tryParse(parts[0].trim());
  final y = double.tryParse(parts[1].trim());
  if (x == null || y == null || !x.isFinite || !y.isFinite) return null;
  return Offset(x, y);
}

/// Why [p] cannot be tapped on a view of [logicalSize] (GLOBAL LOGICAL pixels), or null if it can.
String? tapAtBoundsError(Offset p, Size logicalSize) {
  if (p.dx < 0 ||
      p.dy < 0 ||
      p.dx >= logicalSize.width ||
      p.dy >= logicalSize.height) {
    return 'tap-at (${p.dx},${p.dy}) is outside the view — logical size is '
        '${logicalSize.width} x ${logicalSize.height}';
  }
  return null;
}

int _tapPointer =
    4096; // fresh id per tap — a reused id corrupts the gesture arena across calls

/// Dispatch a synthesized tap (pointer down + up) at [position] — GLOBAL LOGICAL pixels, exactly
/// what framework `PointerEvent.position` carries.
void dispatchLogicalTap(Offset position, {required int viewId}) {
  final pointer = _tapPointer++;
  GestureBinding.instance.handlePointerEvent(
    PointerDownEvent(pointer: pointer, position: position, viewId: viewId),
  );
  GestureBinding.instance.handlePointerEvent(
    PointerUpEvent(pointer: pointer, position: position, viewId: viewId),
  );
}
