/// The line the sim app's main isolate prints once a second. Both halves of
/// the beat live in this driver-agnostic file so the printer (sim_app) and
/// the watcher (sim_harness) cannot drift, and so the clock below is
/// unit-testable without flutter_driver.
const kSimBeatMarker = '[sim-beat]';

/// A wait deadline charged only against inactivity OBSERVED DURING THE WAIT.
///
/// Activity older than [started] never counts toward the wait — a fresh wait
/// always gets its full [budget] of inactivity, no matter how long the
/// activity source had been quiet beforehand. Activity after [started]
/// extends the wait, but never past [hardCap], so a state that stays active
/// without ever delivering the awaited condition still terminates.
class SilentClock {
  final DateTime started;
  final Duration budget;
  final Duration hardCap;

  SilentClock({required this.started, required this.budget, Duration? hardCap})
    : hardCap = hardCap ?? budget * 6;

  DateTime _effectiveActivity(DateTime lastActivityAt) =>
      lastActivityAt.isAfter(started) ? lastActivityAt : started;

  bool expired({required DateTime now, required DateTime lastActivityAt}) =>
      now.difference(_effectiveActivity(lastActivityAt)) >= budget ||
      now.difference(started) >= hardCap;

  String describe({required DateTime now, required DateTime lastActivityAt}) {
    final idle = now.difference(_effectiveActivity(lastActivityAt));
    final elapsed = now.difference(started);
    return '${idle.inSeconds}s inactive during this wait '
        '(${elapsed.inSeconds}s elapsed; budget ${budget.inSeconds}s '
        'inactivity, hard cap ${hardCap.inSeconds}s)';
  }
}
