import 'package:flutter_test/flutter_test.dart';

import 'dart:async';

import '../test_driver/label_resolve.dart';

// The observed failure is TWO IDENTICAL "Close" buttons, not two different labels a loose pattern
// both matched. A resolver built on the deduplicating `semantics().labels()` sees one candidate
// there and reports no problem, so these tests use multiplicity deliberately: a rule that cannot
// tell "one label twice" from "one label once" cannot see the bug this exists for.
LabelCandidate c(String label, {int? hitTestable, int? total}) =>
    LabelCandidate(
      label,
      hitTestable: hitTestable ?? total ?? 1,
      total: total ?? hitTestable ?? 1,
    );

void main() {
  group('matchesLabel', () {
    test(
      'a String must equal the whole label; a RegExp need only be found',
      () {
        expect(matchesLabel('Close', 'Close'), isTrue);
        expect(matchesLabel('Close', 'Close wallet'), isFalse);
        expect(matchesLabel(RegExp('Close'), 'Close wallet'), isTrue);
      },
    );
  });

  group('describeAmbiguity', () {
    test('the observed shape: ONE label, TWO reachable instances', () {
      final d = describeAmbiguity('Close', [
        c('Close', hitTestable: 2, total: 2),
      ]);
      expect(d, contains('2 hit-testable targets'));
      expect(d, contains('"Close" x2'));
      // The duplicate is transient, so the message must offer the settle path rather than only
      // telling the author to write a better label.
      expect(d, contains('tapWhenUnique'));
    });

    test('a loose pattern over DISTINCT labels names each one', () {
      final d = describeAmbiguity(RegExp('Close'), [
        c('Close'),
        c('Close wallet'),
      ]);
      expect(d, contains('2 hit-testable targets'));
      expect(d, contains('"Close"'));
      expect(d, contains('"Close wallet"'));
    });

    test('present but unreachable is NOT reported as ambiguity', () {
      // A covered or zero-sized target is a different failure; calling it ambiguous would send the
      // author off to rename a control that is fine.
      final d = describeAmbiguity('Close', [
        c('Close', hitTestable: 0, total: 2),
      ]);
      expect(d, contains('NONE is hit-testable'));
      expect(d, contains('covered, offstage or zero-sized'));
      expect(d, isNot(contains('tapWhenUnique')));
    });

    test('no match lists what IS reachable, not what is merely on stage', () {
      final d = describeAmbiguity('Nope', [
        c('Close'),
        c('Hidden', hitTestable: 0, total: 1),
      ]);
      expect(d, contains('no hit-testable label matches'));
      expect(d, contains('"Close"'));
      expect(d, isNot(contains('"Hidden"')));
    });

    test('an empty stage says so rather than printing an empty list', () {
      expect(describeAmbiguity('Close', []), contains('(none)'));
    });

    test(
      'exactly one reachable target blames the count changing, not the pattern',
      () {
        // Reached only when the action failed as ambiguous but the follow-up probe sees one: the
        // count moved between the two. Saying "your pattern is ambiguous" there would be false.
        final d = describeAmbiguity('Close', [c('Close')]);
        expect(d, contains('exactly one'));
        expect(d, contains('count changed'));
      },
    );
  });

  group('the probe must agree with the action', () {
    test('driverMatchCount reads the count out of the driver message', () {
      expect(
        driverMatchCount(
          'The finder "Found 2 widgets with widget with semantic label "Close" '
          '(considering only hit-testable widgets with a RenderBox)" ambiguously found '
          'multiple matching widgets.',
        ),
        2,
      );
      expect(driverMatchCount('no count here'), isNull);
    });

    test('agreement is silent', () {
      final d = describeAmbiguity('Close', [
        c('Close', hitTestable: 2, total: 2),
      ], driverCount: 2);
      expect(d, isNot(contains('NOTE')));
    });

    test('DISAGREEMENT is stated, not papered over', () {
      // The probe is a separate observation from the action's own finder. If it counts something
      // different, the message would otherwise present a number the action never saw — in the very
      // text meant to explain what the action did.
      final d = describeAmbiguity('Close', [
        c('Close', hitTestable: 2, total: 2),
      ], driverCount: 3);
      expect(d, contains('the driver matched 3'));
      expect(d, contains('this probe sees 2'));
    });

    test('a disagreement is reported even when the probe sees exactly one', () {
      final d = describeAmbiguity('Close', [c('Close')], driverCount: 2);
      expect(d, contains('the driver matched 2'));
    });
  });

  group('retry policy — counted by ATTEMPTS, not activations', () {
    // A mistaken retry is refused by the session quarantine before it can produce a second
    // activation, so counting taps in the app cannot tell a correct policy from a broken one.
    // These count attempts directly, with an injected clock so nothing waits.
    Future<void> run({
      required Future<void> Function(Duration) attempt,
      Duration timeout = const Duration(seconds: 5),
    }) {
      var now = DateTime(2026);
      return attemptUntilUnique(
        attempt: attempt,
        timeout: timeout,
        target: 'Close',
        clock: () => now,
        pause: (d) async => now = now.add(d),
      );
    }

    test('a timed-out attempt is TERMINAL — exactly one attempt', () async {
      var attempts = 0;
      await expectLater(
        run(
          attempt: (_) async {
            attempts++;
            throw TimeoutException('tap timed out');
          },
        ),
        throwsA(isA<TimeoutException>()),
      );
      expect(
        attempts,
        1,
        reason: 'a timeout may still land; retrying races it',
      );
    });

    test('ANY non-ambiguity failure is terminal too', () async {
      var attempts = 0;
      await expectLater(
        run(
          attempt: (_) async {
            attempts++;
            throw StateError('refused: something is STILL RUNNING');
          },
        ),
        throwsA(isA<StateError>()),
      );
      expect(attempts, 1);
    });

    test('ambiguity retries until it resolves, then stops', () async {
      var attempts = 0;
      await run(
        attempt: (_) async {
          attempts++;
          if (attempts < 3) {
            throw AmbiguousTarget(verb: 'tap("Close")', detail: 'x2');
          }
        },
      );
      expect(attempts, 3, reason: 'stops at the first success — exactly once');
    });

    test(
      'each attempt gets what is LEFT of the deadline, never a fresh budget',
      () async {
        final budgets = <Duration>[];
        await expectLater(
          run(
            attempt: (remaining) async {
              budgets.add(remaining);
              throw AmbiguousTarget(verb: 'tap("Close")', detail: 'x2');
            },
            timeout: const Duration(seconds: 1),
          ),
          throwsA(isA<StateError>()),
        );
        expect(budgets.first, const Duration(seconds: 1));
        // Strictly decreasing: an attempt starting late must not get the full budget again.
        for (var i = 1; i < budgets.length; i++) {
          expect(budgets[i], lessThan(budgets[i - 1]));
        }
        expect(
          budgets.last,
          greaterThanOrEqualTo(const Duration(milliseconds: 500)),
        );
      },
    );

    test('it never dispatches an attempt too small to be meaningful', () async {
      // Otherwise the phases are capped at ~0 and the command fails with "budget 0ms", reporting a
      // stalled action when the caller's deadline is what expired.
      final budgets = <Duration>[];
      await expectLater(
        run(
          attempt: (remaining) async {
            budgets.add(remaining);
            throw AmbiguousTarget(verb: 'tap("Close")', detail: 'x2');
          },
          timeout: const Duration(milliseconds: 900),
        ),
        throwsA(
          isA<StateError>().having(
            (e) => '$e',
            'message',
            contains('never settled'),
          ),
        ),
      );
      expect(
        budgets.every((b) => b >= const Duration(milliseconds: 500)),
        isTrue,
      );
    });
  });

  group('AmbiguousTarget', () {
    test('names the verb and carries the detail', () {
      final e = AmbiguousTarget(
        verb: 'tap("Close")',
        detail: '"Close" names 2 hit-testable targets',
      ).toString();
      expect(e, contains('tap("Close")'));
      expect(e, contains('could not pick a target'));
      expect(e, contains('2 hit-testable targets'));
    });
  });

  group('LabelCandidate.fromJson', () {
    test('reads the app payload, preserving counts', () {
      final parsed = LabelCandidate.fromJson([
        {'label': 'Close', 'hitTestable': 2, 'total': 3},
      ]);
      expect(parsed.single.label, 'Close');
      expect(parsed.single.hitTestable, 2);
      expect(parsed.single.total, 3);
    });
  });
}
