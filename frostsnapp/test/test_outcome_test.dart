import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import '../test_driver/sim_harness.dart' show ExpectedFailure;
import '../test_driver/test_outcome.dart';

// What "the suite is green" means. The rows that matter are the ones where an expectation is
// declared: it must excuse ONLY its own assertion, so an unrelated crash or a timeout in the same
// scenario still fails the run — otherwise a long e2e (launch, keygen, UI, backend, then the
// assertion) would hide real regressions behind its expected one.
void main() {
  const declared =
      '$simTestExpectedFailDeclaredMarker: change index (fixed by f15560fe)';
  const hit = '$simTestExpectedFailHitMarker: change index — expected 0, got 2';

  group('no expectation declared', () {
    test('exit 0 passes', () {
      expect(
        classifyRun(timedOut: false, exitCode: 0, output: 'ALL_OK'),
        'PASSED',
      );
    });

    test('nonzero exit fails', () {
      expect(
        classifyRun(timedOut: false, exitCode: 1, output: 'Bad state: boom'),
        'FAILED',
      );
    });

    test('a timeout is its own verdict', () {
      expect(classifyRun(timedOut: true, exitCode: -1, output: ''), 'TIMEOUT');
    });

    test('the skip marker skips', () {
      expect(
        classifyRun(timedOut: false, exitCode: 0, output: simTestSkippedMarker),
        'SKIPPED',
      );
    });
  });

  group('expectation declared', () {
    test('its assertion failed: xfail', () {
      expect(
        classifyRun(timedOut: false, exitCode: 0, output: '$declared\n$hit'),
        'XFAIL',
      );
    });

    test('its assertion passed: XPASS, a hard failure', () {
      final status = classifyRun(
        timedOut: false,
        exitCode: 0,
        output: '$declared\nCHANGE_INDEX_OK',
      );
      expect(status, 'XPASS');
      expect(statusIsFailure(status), isTrue);
    });

    test('the run never reached the assertion: XPASS, not a pass', () {
      // No hit marker because the scenario returned early — indistinguishable from success
      // unless a missing conclusion is itself a failure. `ExpectedFailure.declare()` is emitted
      // by the runner BEFORE the body precisely so this output is reachable; the integration
      // group below drives the real API to prove it.
      expect(
        classifyRun(timedOut: false, exitCode: 0, output: declared),
        'XPASS',
      );
    });

    test('an UNRELATED failure is still FAILED, not excused', () {
      // The declaration was printed at the start, then the app crashed in the UI long before
      // the designated assertion. This is the case a scenario-wide marker would have hidden.
      expect(
        classifyRun(
          timedOut: false,
          exitCode: 255,
          output: '$declared\nBad state: tap("More") failed: TimeoutException',
        ),
        'FAILED',
      );
    });

    test('a failure AFTER the expected one is still FAILED', () {
      expect(
        classifyRun(
          timedOut: false,
          exitCode: 255,
          output: '$declared\n$hit\nBad state: broadcast failed',
        ),
        'FAILED',
      );
    });

    test('a timeout is still TIMEOUT', () {
      expect(
        classifyRun(timedOut: true, exitCode: -1, output: '$declared\n$hit'),
        'TIMEOUT',
      );
    });

    test('the declaration marker alone cannot be read as a hit', () {
      // The two markers must not be prefix-confusable: a declaration that also matched the hit
      // marker would turn every stale expectation into a silent xfail.
      expect(declared.contains(simTestExpectedFailHitMarker), isFalse);
    });
  });

  // The unit rows above feed classifyRun hand-written output. These drive the REAL API and
  // classify what it actually printed, so the two halves cannot drift: an expectation that is
  // declared but never guarded has to be reachable, or the XPASS row is fiction.
  group('the API produces the output the classifier expects', () {
    /// Capture what a scenario prints, the way the runner sees it.
    Future<String> outputOf(Future<void> Function() scenario) async {
      final out = StringBuffer();
      await runZoned(
        scenario,
        zoneSpecification: ZoneSpecification(
          print: (_, _, _, line) => out.writeln(line),
        ),
      );
      return out.toString();
    }

    test('declared, guard fails -> XFAIL', () async {
      final output = await outputOf(() async {
        final expectation = ExpectedFailure(
          'change index',
          fixedBy: 'f15560fe',
        );
        expectation.declare();
        await expectation.guard(
          () async => throw StateError('expected 0, got 2'),
        );
      });
      expect(
        classifyRun(timedOut: false, exitCode: 0, output: output),
        'XFAIL',
      );
    });

    test('declared, guard passes -> XPASS', () async {
      final output = await outputOf(() async {
        final expectation = ExpectedFailure(
          'change index',
          fixedBy: 'f15560fe',
        );
        expectation.declare();
        await expectation.guard(() async {});
      });
      expect(
        classifyRun(timedOut: false, exitCode: 0, output: output),
        'XPASS',
      );
    });

    test('declared, scenario returns BEFORE its guard -> XPASS', () async {
      // The case the previous API could not express: the declaration was printed by the runner,
      // the body took an early return, and nothing ever tested the expectation.
      final output = await outputOf(() async {
        ExpectedFailure('change index', fixedBy: 'f15560fe').declare();
        return; // never reaches guard
      });
      expect(
        classifyRun(timedOut: false, exitCode: 0, output: output),
        'XPASS',
      );
    });

    test(
      'guard reports whether it was hit, so cleanup can still run',
      () async {
        final expectation = ExpectedFailure('x', fixedBy: 'y');
        expect(
          await expectation.guard(() async => throw StateError('boom')),
          isTrue,
        );
        expect(await expectation.guard(() async {}), isFalse);
      },
    );

    test('a guard only swallows its own assertion', () async {
      // Anything thrown outside the guard propagates: the scenario dies, exits nonzero, FAILED.
      final expectation = ExpectedFailure('change index', fixedBy: 'f15560fe');
      expectation.declare();
      await expectSpecificThrow(expectation);
    });
  });

  group('what counts against the run', () {
    test('passes, skips and xfails do not', () {
      expect(statusIsFailure('PASSED'), isFalse);
      expect(statusIsFailure('SKIPPED'), isFalse);
      expect(statusIsFailure('XFAIL'), isFalse);
    });

    test('failures, timeouts and xpasses do', () {
      expect(statusIsFailure('FAILED'), isTrue);
      expect(statusIsFailure('TIMEOUT'), isTrue);
      expect(statusIsFailure('XPASS'), isTrue);
    });
  });
}

/// An unrelated throw from inside a guarded scenario must escape the guard entirely — the runner
/// then sees a nonzero exit and reports FAILED, never the declared expectation.
Future<void> expectSpecificThrow(ExpectedFailure expectation) async {
  await expectLater(() async {
    await expectation.guard(() async {});
    throw StateError('unrelated crash after the guard');
  }(), throwsA(isA<StateError>()));
}
