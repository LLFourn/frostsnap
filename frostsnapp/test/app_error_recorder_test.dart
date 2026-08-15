import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import '../test_driver/app_error_recorder.dart';

// The no-loss invariant, pinned where it actually lives.
//
// The first version of this endpoint was take-and-clear, and it LOST errors: the clearing happens
// app-side the moment the request runs, so a read the harness abandoned at its deadline could still
// arrive, wipe the queue, and answer nobody. Nothing downstream could tell — the next boundary just
// saw an empty list.
//
// So a read must not consume. Only an id the harness says it ALREADY HAS may be pruned.
const _gen = 'test-generation';

void main() {
  setUp(AppErrorRecorder.instance.resetForTest);

  Map<String, dynamic> envelope(int ackUpTo) =>
      jsonDecode(AppErrorRecorder.instance.readSince(_gen, ackUpTo))
          as Map<String, dynamic>;

  /// The events half of the read. The generation travels alongside them so the harness can tell a
  /// continuation from a fresh app whose ids restarted.
  List<Map<String, dynamic>> read(int ackUpTo) =>
      (envelope(ackUpTo)['events'] as List).cast<Map<String, dynamic>>();

  String generationOf(int ackUpTo) => envelope(ackUpTo)['generation'] as String;

  test(
    'a read does not consume: the same events come back until acknowledged',
    () {
      AppErrorRecorder.instance.recordForTest(
        kind: 'flutter-error',
        summary: 'first',
      );
      AppErrorRecorder.instance.recordForTest(
        kind: 'flutter-error',
        summary: 'second',
      );

      final firstRead = read(0);
      expect(firstRead.map((e) => e['summary']), ['first', 'second']);

      // The abandoned case: the harness never received the above, so its cursor is still 0.
      final retry = read(0);
      expect(
        retry.map((e) => e['summary']),
        ['first', 'second'],
        reason: 'a read the harness gave up on must not have eaten the events',
      );
    },
  );

  test('acknowledging prunes only up to that id, never beyond', () {
    for (final s in ['a', 'b', 'c']) {
      AppErrorRecorder.instance.recordForTest(
        kind: 'flutter-error',
        summary: s,
      );
    }
    final all = read(0);
    expect(all.length, 3);

    // Acknowledge only the first; the rest must survive.
    final afterAck = read(all.first['id'] as int);
    expect(afterAck.map((e) => e['summary']), ['b', 'c']);

    final afterAll = read(afterAck.last['id'] as int);
    expect(afterAll, isEmpty);
  });

  test('ids increase monotonically, so a cursor can never go backwards', () {
    for (final s in ['a', 'b', 'c']) {
      AppErrorRecorder.instance.recordForTest(
        kind: 'flutter-error',
        summary: s,
      );
    }
    final ids = read(0).map((e) => e['id'] as int).toList();
    expect(ids, orderedEquals([...ids]..sort()));
    expect(ids.toSet().length, ids.length, reason: 'ids must be unique');
  });

  test(
    'a STALE generation ack prunes nothing — startup errors survive a restart',
    () {
      // The bug this guards: a cursor of 3 carried across a restart would delete the new generation's
      // ids 1..3 HERE, before the harness could see the token had changed and reset. Errors raised
      // during startup — the ones no test can otherwise reach — would be gone.
      AppErrorRecorder.instance.newGenerationForTest('gen-new');
      for (final s in ['startup-a', 'startup-b']) {
        AppErrorRecorder.instance.recordForTest(
          kind: 'flutter-error',
          summary: s,
        );
      }
      final withStaleAck =
          (jsonDecode(AppErrorRecorder.instance.readSince('gen-old', 99))
              as Map<String, dynamic>);
      expect(
        (withStaleAck['events'] as List).map((e) => e['summary']),
        ['startup-a', 'startup-b'],
        reason:
            'an ack from a previous generation must not delete this one\'s events',
      );
      expect(withStaleAck['generation'], 'gen-new');
    },
  );

  test('every read carries the generation, and a new process changes it', () {
    // Ids restart at 1 in each generation, so the harness must know which one it is reading —
    // otherwise a cursor carried across a restart prunes the new generation's first errors.
    AppErrorRecorder.instance.recordForTest(
      kind: 'flutter-error',
      summary: 'a',
    );
    final before = generationOf(0);
    expect(before, isNotEmpty);

    AppErrorRecorder.instance.newGenerationForTest('gen-two');
    AppErrorRecorder.instance.recordForTest(
      kind: 'flutter-error',
      summary: 'b',
    );
    expect(generationOf(0), 'gen-two');
    expect(generationOf(0), isNot(before));
    expect(read(0).single['id'], 1, reason: 'ids restart in a new generation');
  });

  test(
    'an id the recorder never issued prunes nothing beyond what it names',
    () {
      AppErrorRecorder.instance.recordForTest(
        kind: 'flutter-error',
        summary: 'only',
      );
      final id = read(0).single['id'] as int;
      expect(read(id - 1).single['summary'], 'only');
    },
  );
}
