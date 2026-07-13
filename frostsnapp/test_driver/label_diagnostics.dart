// fsim-label-diagnostics: a failed driver call must say WHICH of three very different things
// happened — the label never matched, the app process died, or the VM-service connection dropped —
// instead of every one surfacing as a 20s hang and "Lost connection to device". This module is the
// PURE classifier + formatter; the harness injects the cached app-exit status, the RAW snapshot
// probe (un-diagnosed transport — the probe must never classify itself), and the app-log tail.

/// How [finder] matches labels — the diagnostic mirror of `find.bySemanticsLabel`: a String matches
/// EXACTLY (substring would silently change what every test targets); any other Pattern by
/// containment.
bool labelMatchesAny(Pattern finder, List<String> labels) => labels.any(
  (l) => finder is String ? l == finder : finder.allMatches(l).isNotEmpty,
);

/// The label-miss error text: what was attempted, what IS on stage, and — for an exact-String miss
/// whose text appears INSIDE a merged label — the RegExp hint that unblocks it.
String labelMissError(
  Pattern finder,
  List<String> onStage, {
  int listLimit = 20,
}) {
  if (finder is String) {
    final containing = onStage.where((l) => l.contains(finder)).toList();
    if (containing.isNotEmpty) {
      return 'no EXACT label match for "$finder" — labels CONTAINING it: '
          '${containing.map((l) => '"$l"').join(', ')}. '
          'Use a RegExp for substring matching, e.g. tap(RegExp(r"..."))';
    }
  }
  final shown = onStage.take(listLimit).map((l) => '"$l"').join(', ');
  final more = onStage.length > listLimit
      ? ' (+${onStage.length - listLimit} more)'
      : '';
  return 'no on-stage label matches "$finder" — on stage: '
      '${onStage.isEmpty ? '(none)' : '$shown$more'}';
}

/// The exhausted-tapUntil error. [probedLabels] is the best-effort on-stage listing (null when the
/// probe itself failed). The miss formatter assumes ZERO matches — if [expect] appeared between the
/// last wait and the probe, saying "no match" while listing the matching label would be absurd, so
/// that case reports the timing/action truth instead.
String tapUntilExhaustedError(
  Pattern label,
  Pattern expect,
  int tries,
  List<String>? probedLabels,
) {
  final base = 'tapped "$label" $tries times but "$expect" never appeared';
  if (probedLabels == null) return base;
  if (labelMatchesAny(expect, probedLabels)) {
    return '$base within the waits — it IS on stage now (timing/animation issue, not a label miss)';
  }
  return '$base — ${labelMissError(expect, probedLabels)}';
}

enum DriverFailureKind {
  appExited,
  labelMiss,
  actionFailure,
  connectionFailure,
}

class DriverDiagnosis {
  final DriverFailureKind kind;
  final String message;
  DriverDiagnosis(this.kind, this.message);
}

/// Classify ONE driver-call failure. [appExitStatus] reads the session's CACHED exit code (never
/// awaits — re-read after a failed probe so a just-completed force-stop wins over "connection").
/// [probeLabels] is the RAW snapshot probe: called AT MOST ONCE, and its own failure must reach the
/// connection outcome here — never recurse into another diagnosis. [finder] is the FINDER-phase
/// Pattern, or null for non-finder calls (typing, requestData, waitForAbsent …), which can never be
/// classified as a label miss.
Future<DriverDiagnosis> diagnoseDriverFailure({
  required Object original,
  required String verb,
  required Pattern? finder,
  required int? Function() appExitStatus,
  required Future<List<String>> Function() probeLabels,
  required String Function() appLogTail,
  // On ANDROID the cached exit is the HOST-side `flutter run` process, which notices an on-device
  // force-stop a beat after the driver connection drops — a failed probe polls the cache for this
  // grace window so a dying app classifies as app-exited, not as a connection drop. [wait] is
  // injectable so the grace loop is unit-testable without real time.
  Duration exitGrace = const Duration(seconds: 5),
  Future<void> Function(Duration) wait = Future.delayed,
}) async {
  DriverDiagnosis appExited(int code) => DriverDiagnosis(
    DriverFailureKind.appExited,
    'the app process exited (code $code) during $verb — recent app log:\n${appLogTail()}',
  );
  final exitBefore = appExitStatus();
  if (exitBefore != null) return appExited(exitBefore);
  List<String> labels;
  try {
    labels = await probeLabels();
  } catch (probeErr) {
    const pollEvery = Duration(milliseconds: 250);
    var waited = Duration.zero;
    while (true) {
      final exitAfter = appExitStatus();
      if (exitAfter != null) return appExited(exitAfter);
      if (waited >= exitGrace) break;
      await wait(pollEvery);
      waited += pollEvery;
    }
    return DriverDiagnosis(
      DriverFailureKind.connectionFailure,
      'driver/VM-service unreachable during $verb (semantics probe failed: $probeErr) — '
      'original error: $original',
    );
  }
  if (finder != null && !labelMatchesAny(finder, labels)) {
    // A confident label miss does NOT append the raw driver error — "Lost connection to device"
    // text on a plain miss is exactly the misdirection this exists to kill.
    return DriverDiagnosis(
      DriverFailureKind.labelMiss,
      '$verb failed: ${labelMissError(finder, labels)}',
    );
  }
  return DriverDiagnosis(
    DriverFailureKind.actionFailure,
    '$verb failed'
    '${finder != null ? ' (the label "$finder" IS on stage — action/driver failure, not a label miss)' : ''}'
    ': $original',
  );
}
