import 'dart:async';

import 'package:flutter/material.dart';

/// A SIM-ONLY fixture that puts N controls carrying the SAME semantic label on screen, so
/// "two identical hit-testable targets" can be a test rather than a flake.
///
/// That shape is the one that actually breaks a tap — two sheets stacked while one closes, both
/// still offering "Close" — and it cannot be built from ordinary app state on demand. Two DIFFERENT
/// labels caught by one loose pattern is a different, easier bug and reproducing it instead would
/// leave the real one untested.
class SimDuplicateTargets {
  SimDuplicateTargets._();
  static final SimDuplicateTargets instance = SimDuplicateTargets._();

  final ValueNotifier<({String label, int count})?> state = ValueNotifier(null);

  /// Activations since [show], so a settle test can assert an action fired EXACTLY once rather
  /// than trusting a retry loop not to double-fire.
  int taps = 0;

  Timer? _settle;

  /// When set, a tap RECORDS itself and then blocks the UI isolate for this long. That is what
  /// makes an ACTION time out: frame-sync-off and the finder both complete, the tap is dispatched
  /// exactly once, and only then does the app stop answering. Stalling the app beforehand instead
  /// times out the first frame-sync phase and never dispatches anything.
  Duration blockOnTap = Duration.zero;

  /// Show [count] controls labelled [label]. After [settleAfter], drop to a single one — the
  /// transient-duplicate case a caller is meant to wait out rather than rename around.
  void show(String label, int count, {Duration? settleAfter}) {
    _settle?.cancel();
    taps = 0;
    state.value = (label: label, count: count);
    if (settleAfter != null) {
      _settle = Timer(settleAfter, () {
        if (state.value?.label == label) state.value = (label: label, count: 1);
      });
    }
  }

  void clear() {
    _settle?.cancel();
    _settle = null;
    state.value = null;
    taps = 0;
    blockOnTap = Duration.zero;
  }

  /// Record the activation, then block for [blockOnTap]. The count is incremented FIRST so a test
  /// can prove the action was dispatched even though it never returned.
  void onTapped() {
    taps++;
    if (blockOnTap == Duration.zero) return;
    final until = DateTime.now().add(blockOnTap);
    while (DateTime.now().isBefore(until)) {
      // busy — deliberately not an await, or the isolate would keep answering
    }
  }
}

/// The fixture's controls, stacked above everything so they are genuinely hit-testable.
class SimDuplicateTargetLayer extends StatelessWidget {
  const SimDuplicateTargetLayer({super.key});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: SimDuplicateTargets.instance.state,
    builder: (context, value, _) {
      if (value == null) return const SizedBox.shrink();
      return Positioned(
        key: const ValueKey('sim-duplicate-targets'),
        top: 0,
        left: 0,
        child: Material(
          type: MaterialType.transparency,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // A scope whose ROOT carries the label — the `matchRoot: true` case. Without it every
              // scoped assertion would match a descendant, and a probe that skipped the scope root
              // would still agree with the action by accident.
              Semantics(
                key: const ValueKey('sim-scope-root'),
                container: true,
                button: true,
                label: 'RootScopeProbe',
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: SimDuplicateTargets.instance.onTapped,
                  child: const SizedBox(width: 80, height: 24),
                ),
              ),
              for (var i = 0; i < value.count; i++)
                Semantics(
                  container: true,
                  button: true,
                  label: value.label,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: SimDuplicateTargets.instance.onTapped,
                    child: const SizedBox(width: 80, height: 24),
                  ),
                ),
            ],
          ),
        ),
      );
    },
  );
}

/// SIM-ONLY: make the app raise a real Flutter error on demand, one per source, so the harness's
/// detection is a test rather than something that only fires when something else is already broken.
class SimErrorProvoker {
  SimErrorProvoker._();
  static final SimErrorProvoker instance = SimErrorProvoker._();

  final ValueNotifier<bool> throwInBuild = ValueNotifier(false);

  /// Throw from inside `build` — the RED SCREEN case. Flutter reports it through
  /// `FlutterError.onError` and then swaps the subtree for an ErrorWidget, so the app keeps
  /// running and a test can sail straight past a screen that is visibly rubble.
  void buildFailure() => throwInBuild.value = true;

  /// Throw asynchronously, escaping into the zone rather than any awaiting caller.
  void asyncFailure({Duration after = Duration.zero}) {
    Timer(after, () => throw StateError('sim: deliberate async failure'));
  }

  /// A framework error that is NOT a build failure and renders nothing: reported through
  /// FlutterError.onError alone.
  void frameworkFailure() {
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: StateError('sim: deliberate framework failure'),
        library: 'sim harness',
        context: ErrorDescription('provoked deliberately'),
      ),
    );
  }

  /// Show a TAPPABLE control that destroys itself: tapping it arms the build failure, and the
  /// control lives inside the subtree that then throws — so the label the driver just acted on is
  /// gone, replaced by the error widget. That is the shape where finder diagnosis would rewrite
  /// "the app threw" into "no such label" if the app error were not given precedence.
  final ValueNotifier<bool> showTappable = ValueNotifier(false);

  static const tappableLabel = 'ProvokeBuildTarget';

  void armTappable() => showTappable.value = true;

  void clear() {
    throwInBuild.value = false;
    showTappable.value = false;
  }
}

/// Renders the build failure when armed. Kept beside the tray so it is inside the app's tree.
class SimErrorProvokerLayer extends StatelessWidget {
  const SimErrorProvokerLayer({super.key});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: SimErrorProvoker.instance.throwInBuild,
    builder: (context, armed, _) {
      if (armed) throw StateError('sim: deliberate build failure');
      return ValueListenableBuilder(
        valueListenable: SimErrorProvoker.instance.showTappable,
        builder: (context, tappable, _) {
          if (!tappable) return const SizedBox.shrink();
          return Semantics(
            container: true,
            button: true,
            label: SimErrorProvoker.tappableLabel,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: SimErrorProvoker.instance.buildFailure,
              child: const SizedBox(width: 80, height: 24),
            ),
          );
        },
      );
    },
  );
}
