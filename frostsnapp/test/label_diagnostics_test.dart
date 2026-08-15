import 'dart:async';
import 'dart:io';

import 'package:flutter_driver/flutter_driver.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test_driver/label_diagnostics.dart';
import '../test_driver/sim_harness.dart';

// fsim-label-diagnostics: the classifier is why a failed tap says WHAT happened. Wrong here =
// hours lost to "Lost connection to device" covering a plain label typo (the PR-505 experience).
void main() {
  group('labelMissError', () {
    const merged = 'Create a multi-sig wallet\nSet up a secure wallet';
    const onStage = [merged, 'Restore wallet', 'Open navigation menu'];

    test('exact miss whose text is INSIDE a merged label suggests RegExp', () {
      final msg = labelMissError('Create a multi-sig wallet', onStage);
      expect(msg, contains('no EXACT label match'));
      expect(msg, contains(merged));
      expect(msg, contains('RegExp'));
    });

    test('miss with no substring hits lists the on-stage labels', () {
      final msg = labelMissError('Nonexistent', onStage);
      expect(msg, contains('no on-stage label matches'));
      expect(msg, contains('Restore wallet'));
    });

    test('listing is bounded with a +N more tail', () {
      final many = List.generate(30, (i) => 'label-$i');
      final msg = labelMissError('x', many, listLimit: 20);
      expect(msg, contains('label-19'));
      expect(msg, isNot(contains('label-20')));
      expect(msg, contains('+10 more'));
    });

    test('RegExp miss lists labels; empty stage says none', () {
      expect(labelMissError(RegExp('zzz'), onStage), contains('Restore'));
      expect(labelMissError('x', const []), contains('(none)'));
    });
  });

  group('labelMatchesAny', () {
    test('String is exact; RegExp is containment', () {
      const labels = ['a\nb', 'plain'];
      expect(labelMatchesAny('a', labels), isFalse);
      expect(labelMatchesAny('plain', labels), isTrue);
      expect(labelMatchesAny(RegExp('a'), labels), isTrue);
    });
  });

  group('diagnoseDriverFailure', () {
    test('cached app exit wins immediately — probe never called', () async {
      var probes = 0;
      final d = await diagnoseDriverFailure(
        original: 'orig',
        verb: 'tap("x")',
        finder: 'x',
        appExitStatus: () => 137,
        probeLabels: () async {
          probes++;
          return [];
        },
        appLogTail: () => 'OOM kill',
      );
      expect(d.kind, DriverFailureKind.appExited);
      expect(d.message, contains('code 137'));
      expect(d.message, contains('OOM kill'));
      expect(probes, 0);
    });

    test(
      'zero matches with finder context → label miss, RAW error dropped',
      () async {
        final d = await diagnoseDriverFailure(
          original: 'Lost connection to device',
          verb: 'tap("Create a multi-sig wallet")',
          finder: 'Create a multi-sig wallet',
          appExitStatus: () => null,
          probeLabels: () async => ['Create a multi-sig wallet\nSet up…'],
          appLogTail: () => '',
        );
        expect(d.kind, DriverFailureKind.labelMiss);
        expect(d.message, contains('RegExp'));
        expect(d.message, isNot(contains('Lost connection')));
      },
    );

    test('matching label → action failure PRESERVING the original', () async {
      final d = await diagnoseDriverFailure(
        original: 'DriverError: tap timed out',
        verb: 'tap("Next")',
        finder: 'Next',
        appExitStatus: () => null,
        probeLabels: () async => ['Next'],
        appLogTail: () => '',
      );
      expect(d.kind, DriverFailureKind.actionFailure);
      expect(d.message, contains('IS on stage'));
      expect(d.message, contains('DriverError: tap timed out'));
    });

    test('no finder context can never be a label miss', () async {
      final d = await diagnoseDriverFailure(
        original: 'boom',
        verb: 'requestData',
        finder: null,
        appExitStatus: () => null,
        probeLabels: () async => [],
        appLogTail: () => '',
      );
      expect(d.kind, DriverFailureKind.actionFailure);
      expect(d.message, contains('boom'));
    });

    test(
      'failed probe → ONE probe call, connection failure with original',
      () async {
        var probes = 0;
        var waits = 0;
        final d = await diagnoseDriverFailure(
          original: 'orig-err',
          verb: 'waitFor("x")',
          finder: 'x',
          appExitStatus: () => null,
          probeLabels: () async {
            probes++;
            throw StateError('socket closed');
          },
          appLogTail: () => '',
          wait: (_) async => waits++,
        );
        expect(probes, 1, reason: 'the probe must never recurse');
        expect(waits, greaterThan(0), reason: 'the grace window was polled');
        expect(d.kind, DriverFailureKind.connectionFailure);
        expect(d.message, contains('unreachable'));
        expect(d.message, contains('orig-err'));
      },
    );

    test(
      'failed probe + exit landing INSIDE the grace window → app exited '
      '(android force-stop: flutter run exits a beat after the connection drops)',
      () async {
        var polls = 0;
        final d = await diagnoseDriverFailure(
          original: 'orig',
          verb: 'waitFor("x")',
          finder: 'x',
          // null on the first two reads; the cached exit lands on the third.
          appExitStatus: () => ++polls >= 3 ? 143 : null,
          probeLabels: () async => throw StateError('gone'),
          appLogTail: () => 'force-stopped',
          wait: (_) async {},
        );
        expect(d.kind, DriverFailureKind.appExited);
        expect(d.message, contains('code 143'));
        expect(d.message, contains('force-stopped'));
      },
    );
  });

  group('tapUntilExhaustedError', () {
    test('probe failed (null) → plain exhaustion error', () {
      final msg = tapUntilExhaustedError('Next', 'Done', 8, null);
      expect(msg, contains('tapped "Next" 8 times'));
      expect(msg, isNot(contains('on stage')));
    });

    test(
      'expect appeared between wait and probe → timing truth, not a miss',
      () {
        final msg = tapUntilExhaustedError('Next', 'Done', 8, [
          'Done',
          'Other',
        ]);
        expect(msg, contains('IS on stage now'));
        expect(msg, isNot(contains('no on-stage label matches')));
      },
    );

    test('expect truly absent → the miss listing', () {
      final msg = tapUntilExhaustedError('Next', 'Done', 8, ['Other']);
      expect(msg, contains('no on-stage label matches'));
      expect(msg, contains('Other'));
    });
  });

  group('composite diagnosis wiring', () {
    test(
      'a failing composite (tapTooltip) probes EXACTLY once — one diagnosis '
      'per failing operation, no nested classification',
      () async {
        final driver = _ThrowingDriver();
        final session = AppSession(
          _FakeProcess(),
          Directory('unused'),
          driver,
          <String>[],
          'macos',
          true,
        );
        Object? err;
        try {
          await session.tapTooltip('anything');
        } catch (e) {
          err = e;
        }
        // 1 = the composite's own RAW snapshot fetch; 2 = the ONE classifier probe. A diagnosed
        // inner transport would classify the same failure again and push this to 3+.
        expect(driver.requestDataCalls, 2);
        expect('$err', contains('unreachable'));
      },
      timeout: const Timeout(
        Duration(minutes: 1),
      ), // includes the 5s exit-grace poll
    );
  });
}

class _ThrowingDriver implements FlutterDriver {
  int requestDataCalls = 0;

  @override
  Future<String> requestData(String? message, {Duration? timeout}) async {
    requestDataCalls++;
    throw StateError('connection torn down');
  }

  @override
  Future<T> runUnsynchronized<T>(
    Future<T> Function() action, {
    Duration? timeout,
  }) => action();

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _FakeProcess implements Process {
  @override
  Future<int> get exitCode => Completer<int>().future; // never exits

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}
