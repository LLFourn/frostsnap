import 'dart:async';

/// The generational app-process lifecycle behind `restartApp` (fsim-app-restart).
///
/// The serve daemon tears the whole session down when the app process exits — the
/// app-death analogue of the regtest death-pipe. A restart kills exactly that process,
/// so the runtime must distinguish three exits:
///
/// - the OLD generation dying during a restart window: EXPECTED, suppressed;
/// - the CURRENT generation dying any other time: unexpected and TERMINAL —
///   [isDead] flips, [unexpectedExit] fires, and the daemon tears down as it
///   always did;
/// - a FAILED relaunch: the runtime becomes terminally [isDead] and
///   [unexpectedExit] fires, so the daemon still tears down cleanly instead of
///   half-living against nothing.
///
/// Restart is SINGLE-FLIGHT: a second overlapping restart is rejected — two callers
/// marking/installing generations concurrently could suppress a real death or watch
/// the wrong process. Process-independent by construction (exit futures and the
/// relaunch action are injected), so the whole contract is unit-testable.
class GenerationalRuntime {
  int _generation = 0;
  bool _restarting = false;
  bool _dead = false;
  final Completer<int> _unexpectedExit = Completer<int>();

  /// Fires ONCE, with the exit code, when the current generation exits outside a
  /// restart window — or with the failed relaunch marker (-1) when a restart could
  /// not produce a new generation. The daemon's teardown watcher awaits this.
  Future<int> get unexpectedExit => _unexpectedExit.future;

  /// Terminal: a relaunch failed and no generation is running. Every later
  /// operation on the session should error.
  bool get isDead => _dead;

  bool get restartInFlight => _restarting;

  /// Watch [exit] as the CURRENT generation's exit. An exit reported by a stale
  /// generation (superseded by a restart) is ignored; the current generation's
  /// exit outside a restart window is TERMINAL — [isDead] flips (no generation is
  /// running, so a later restart has nothing to kill) and [unexpectedExit] fires.
  void watch(Future<int> exit) {
    final generation = _generation;
    unawaited(
      exit.then((code) {
        if (_generation != generation || _dead) return;
        if (_restarting)
          return; // the old generation dying is the restart itself
        _dead = true;
        if (!_unexpectedExit.isCompleted) _unexpectedExit.complete(code);
      }),
    );
  }

  /// Run one restart: [relaunch] must kill the old generation, bring up the new
  /// one, and return the NEW generation's exit future. On success the new
  /// generation is installed and watched; on failure the runtime is terminally
  /// dead and [unexpectedExit] fires so the daemon tears down.
  Future<void> restart(Future<Future<int>> Function() relaunch) async {
    if (_dead) {
      throw StateError(
        'the app runtime is dead (the app exited, or a relaunch failed)',
      );
    }
    if (_restarting) {
      throw StateError('a restart is already in flight');
    }
    _restarting = true;
    try {
      final newExit = await relaunch();
      _generation += 1;
      _restarting = false;
      watch(newExit);
    } catch (e) {
      _dead = true;
      _restarting = false;
      if (!_unexpectedExit.isCompleted) _unexpectedExit.complete(-1);
      rethrow;
    }
  }
}
