import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../test_driver/diagnostic_rerun.dart';

// fsim-failure-video: the pure decision logic behind `fsim test --record-failures` (android-only). The
// re-runs are a POST-BATCH diagnostic phase — selection must never mutate the frozen primary results, and
// the sequential runner must isolate each re-run (solo recording) while a failing item never blocks the
// rest (an escaping exception would change fsim's exit code).
void main() {
  group('recordFailuresUsageError', () {
    test('without --android is rejected (no host recorder)', () {
      expect(recordFailuresUsageError(android: false), isNotNull);
    });

    test('with --android is allowed (records the emulator, any host OS)', () {
      expect(recordFailuresUsageError(android: true), isNull);
    });
  });

  group('selectDiagnosticReruns', () {
    // (status, name) stand-ins for frozen _TestResults.
    final results = [
      (status: 'PASSED', name: 'a'),
      (status: 'FAILED', name: 'b'),
      (status: 'SKIPPED', name: 'c'),
      (status: 'TIMEOUT', name: 'd'),
      (status: 'FAILED', name: 'e'),
    ];
    bool isFinalFailure(({String status, String name}) r) =>
        r.status != 'PASSED' && r.status != 'SKIPPED';

    test('disabled selects nothing', () {
      expect(selectDiagnosticReruns(results, false, isFinalFailure), isEmpty);
    });

    test('selects only final failures (incl. timeouts), in batch order', () {
      final selected = selectDiagnosticReruns(results, true, isFinalFailure);
      expect(selected.map((r) => r.name), ['b', 'd', 'e']);
    });

    test('never mutates the frozen primary results', () {
      final before = List.of(results);
      selectDiagnosticReruns(results, true, isFinalFailure);
      expect(results, before);
    });
  });

  group('usableSegments', () {
    test('keeps only existing non-empty files, preserving order', () async {
      final dir = await Directory.systemTemp.createTemp('fsim-seg-test');
      addTearDown(() => dir.delete(recursive: true));
      final good1 = File('${dir.path}/rerun-0.mp4')
        ..writeAsBytesSync([1, 2, 3]);
      final empty = File('${dir.path}/rerun-1.mp4')..writeAsBytesSync([]);
      final missing = '${dir.path}/rerun-2.mp4';
      final good2 = File('${dir.path}/rerun-3.mp4')..writeAsBytesSync([4]);
      expect(
        await usableSegments([good1.path, empty.path, missing, good2.path]),
        [good1.path, good2.path],
      );
    });

    test('empty input yields no segments', () async {
      expect(await usableSegments([]), isEmpty);
    });
  });

  group('runSequentially', () {
    test('max concurrency is ONE and invocation order is preserved', () async {
      final events = <String>[];
      var active = 0;
      var maxActive = 0;
      // Later items complete FASTER — under any parallelism they would finish out of order and
      // maxActive would exceed 1.
      final delays = [30, 10, 1];
      await runSequentially([0, 1, 2], (i) async {
        active++;
        maxActive = maxActive < active ? active : maxActive;
        events.add('start $i');
        await Future<void>.delayed(Duration(milliseconds: delays[i]));
        events.add('end $i');
        active--;
      }, (_, _) {});
      expect(maxActive, 1);
      expect(events, [
        'start 0',
        'end 0',
        'start 1',
        'end 1',
        'start 2',
        'end 2',
      ]);
    });

    test('a failing item is reported and never blocks later items', () async {
      final ran = <int>[];
      final errors = <(int, Object)>[];
      await runSequentially([0, 1, 2], (i) async {
        if (i == 1) throw StateError('boom');
        ran.add(i);
      }, (i, e) => errors.add((i, e)));
      expect(ran, [0, 2]);
      expect(errors.length, 1);
      expect(errors.single.$1, 1);
    });

    test('never mutates the frozen input collection', () async {
      final items = [1, 2, 3];
      final before = List.of(items);
      await runSequentially(items, (_) async {}, (_, _) {});
      expect(items, before);
    });
  });
}
