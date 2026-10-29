import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// A SIM-ONLY patch that a screen recording can find, so the recording's timeline can be pinned to
/// the clock that stamps device frames.
///
/// It sits on the left edge at mid-height. The status bar covers the top of the screen and the
/// navigation bar the bottom, and neither may hide it.
class SimRecordingMarker {
  SimRecordingMarker._();
  static final SimRecordingMarker instance = SimRecordingMarker._();

  static const color = Color(0xFFFF00FF);
  static const size = 48.0;

  final ValueNotifier<({Completer<int> drawn, int Function() now})?> _showing =
      ValueNotifier(null);

  /// Show the patch for [duration]. Completes with [now] as read after the first frame that drew
  /// it.
  Future<int> show(Duration duration, {required int Function() now}) {
    final drawn = Completer<int>();
    final showing = (drawn: drawn, now: now);
    _showing.value = showing;
    WidgetsBinding.instance.scheduleFrame();
    Timer(duration, () {
      if (identical(_showing.value, showing)) _showing.value = null;
    });
    return drawn.future;
  }
}

class SimRecordingMarkerLayer extends StatelessWidget {
  const SimRecordingMarkerLayer({super.key});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: SimRecordingMarker.instance._showing,
    builder: (context, showing, _) {
      if (showing == null) return const SizedBox.shrink();
      final (:drawn, :now) = showing;
      if (!drawn.isCompleted) {
        SchedulerBinding.instance.addPostFrameCallback((_) {
          if (!drawn.isCompleted) drawn.complete(now());
        });
      }
      return const Positioned(
        left: 0,
        top: 0,
        bottom: 0,
        child: IgnorePointer(
          child: ExcludeSemantics(
            child: Center(
              child: SizedBox.square(
                dimension: SimRecordingMarker.size,
                child: ColoredBox(color: SimRecordingMarker.color),
              ),
            ),
          ),
        ),
      );
    },
  );
}
