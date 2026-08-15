/// Turning "that label names more than one control" into a statement about the TEST's target
/// rather than about Flutter's widget tree. Dependency-free so the rules are unit-testable without
/// a driver or an app (`test/label_resolve_test.dart`), the same shape as `tooltip_resolve.dart`.
library;

/// One on-stage label and how many of its instances a tap could reach.
class LabelCandidate {
  final String label;

  /// Instances a tap could actually reach — the set a singular action must find exactly one of.
  final int hitTestable;

  /// Instances present at all. A label with [total] > [hitTestable] is on stage but partly
  /// unreachable (covered, offstage, zero-sized), which is a different problem from ambiguity and
  /// worth naming rather than silently ignoring.
  final int total;

  const LabelCandidate(
    this.label, {
    required this.hitTestable,
    required this.total,
  });

  static List<LabelCandidate> fromJson(List<dynamic> json) => [
    for (final entry in json.cast<Map<String, dynamic>>())
      LabelCandidate(
        entry['label'] as String,
        hitTestable: entry['hitTestable'] as int,
        total: entry['total'] as int,
      ),
  ];
}

/// Whether [pattern] matches [label], with the same semantics as the finders: a String must equal
/// the whole label, a RegExp needs only to be found in it.
bool matchesLabel(Pattern pattern, String label) =>
    pattern is String ? label == pattern : pattern.allMatches(label).isNotEmpty;

/// Why a singular action could not pick a target, in the test's own vocabulary.
///
/// FlutterDriver reports this as `Found 2 widgets … ambiguously found multiple matching widgets`,
/// which describes its finder rather than the choice the test failed to make. Ambiguity is not
/// always the test's fault — two controls genuinely coexist for a few frames mid-transition — so
/// the message has to carry enough to tell those apart: which labels matched, and how many
/// reachable instances each has.
/// How many widgets FlutterDriver itself matched, from its message. The probe below is a SEPARATE
/// observation taken after the fact, so this is the only way to check the two agree.
int? driverMatchCount(String driverMessage) => int.tryParse(
  RegExp(r'Found (\d+) widgets').firstMatch(driverMessage)?.group(1) ?? '',
);

String describeAmbiguity(
  Pattern pattern,
  List<LabelCandidate> candidates, {
  int? driverCount,
  String? within,
}) {
  final scope = within == null ? '' : ' within "$within"';
  final matched = candidates
      .where((c) => matchesLabel(pattern, c.label))
      .toList();
  final reachable = matched.where((c) => c.hitTestable > 0).toList();

  if (reachable.isEmpty) {
    final present = matched.where((c) => c.total > 0).toList();
    if (present.isEmpty) {
      final all = candidates
          .where((c) => c.hitTestable > 0)
          .map((c) => '"${c.label}"');
      return 'no hit-testable label matches "$pattern"$scope — reachable labels: '
          '${all.isEmpty ? '(none)' : all.join(', ')}';
    }
    return '"$pattern" matches ${_instances(present)}$scope, but NONE is hit-testable — '
        'the target is covered, offstage or zero-sized rather than ambiguous';
  }

  final total = reachable.fold<int>(0, (sum, c) => sum + c.hitTestable);
  // The counts must come from the same criterion the ACTION used, or this message misdescribes the
  // failure it exists to explain. They are separate observations, so when they disagree say so
  // rather than presenting a number the action never saw.
  final disagreement = driverCount != null && driverCount != total
      ? ' (NOTE: the driver matched $driverCount, this probe sees $total — either the screen '
            'changed between them, or the probe is not counting what the action counts)'
      : '';
  if (total == 1) {
    return '"$pattern" resolves to exactly one hit-testable target$scope — if the action still '
        'failed, '
        'the count changed underneath it$disagreement';
  }
  // Naming the counts is the point: one label twice is a transient duplicate (wait for it to
  // settle), several labels once each is a pattern that is too loose (name it better).
  return '"$pattern" names $total hit-testable targets$scope — ${_instances(reachable)}. '
      'A singular action needs exactly one: tighten the pattern, or use tapWhenUnique if the '
      'duplicate is transient (two controls stacked mid-transition).$disagreement';
}

String _instances(List<LabelCandidate> candidates) => candidates
    .map(
      (c) => c.hitTestable == c.total && c.hitTestable == 1
          ? '"${c.label}"'
          : '"${c.label}" x${c.hitTestable == 0 ? c.total : c.hitTestable}',
    )
    .join(', ');

/// A singular action found more than one target (or none it could reach).
///
/// Distinct from a timeout: the driver raises ambiguity while RESOLVING the finder, before it
/// dispatches the action, so nothing has been done to the app. That is what makes retrying it safe
/// — and what makes retrying a timeout unsafe, since a timed-out action may still land.
class AmbiguousTarget implements Exception {
  final String verb;
  final String detail;

  AmbiguousTarget({required this.verb, required this.detail});

  @override
  String toString() => '$verb could not pick a target: $detail';
}

/// Retry a singular action until it names exactly one target, with [timeout] as the OPERATION's
/// deadline rather than a per-attempt budget.
///
/// The decision boundary is the ACTION: only [AmbiguousTarget] is retried, because the driver
/// raises it while RESOLVING the finder, before dispatch, so nothing has happened. Every other
/// outcome — a timeout above all — is terminal: it may have landed, and a second attempt would race
/// the first. Kept here, injectable, because "did it retry?" cannot be answered from the app: a
/// mistaken retry is refused by the session quarantine before it can produce a second activation,
/// so counting activations cannot tell a correct policy from a broken one. Counting ATTEMPTS can.
Future<void> attemptUntilUnique({
  required Future<void> Function(Duration remaining) attempt,
  required Duration timeout,
  required String target,
  DateTime Function() clock = _wallClock,
  Future<void> Function(Duration) pause = _realPause,
  Duration minAttempt = const Duration(milliseconds: 500),
  Duration betweenAttempts = const Duration(milliseconds: 100),
}) async {
  final deadline = clock().add(timeout);
  var attempts = 0;
  String? lastDetail;
  while (true) {
    final remaining = deadline.difference(clock());
    // Below a usable minimum there is no point dispatching: the phases would be capped at ~0 and
    // fail instantly, reporting a stalled action where the truth is the caller's time ran out.
    if (remaining < minAttempt) {
      throw StateError(
        'tapWhenUnique("$target") never settled to one target in ${timeout.inSeconds}s '
        '($attempts attempts)${lastDetail == null ? '' : '; last: $lastDetail'}',
      );
    }
    attempts++;
    try {
      await attempt(remaining);
      return;
    } on AmbiguousTarget catch (e) {
      lastDetail = e.detail;
      await pause(betweenAttempts);
    }
  }
}

DateTime _wallClock() => DateTime.now();
Future<void> _realPause(Duration d) => Future<void>.delayed(d);
