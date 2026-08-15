import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import '../test_driver/generational_runtime.dart';

// The restartApp lifecycle contract (fsim-app-restart), process-independent: the
// daemon tears the session down on the app's unexpected exit, and a restart kills
// exactly that process — so expected old-generation exits must be suppressed,
// unexpected exits must still fire, a failed relaunch must land in a terminal dead
// state that STILL fires teardown, and restarts are single-flight.
void main() {
  test(
    'the old generation dying during a restart is expected — suppressed',
    () async {
      final runtime = GenerationalRuntime();
      final gen1 = Completer<int>();
      runtime.watch(gen1.future);

      final gen2 = Completer<int>();
      await runtime.restart(() async {
        gen1.complete(0); // the kill — during the restart window
        await Future<void>.delayed(Duration.zero);
        return gen2.future;
      });

      var fired = false;
      unawaited(runtime.unexpectedExit.then((_) => fired = true));
      await Future<void>.delayed(Duration.zero);
      expect(fired, isFalse, reason: 'the restart kill is not a death');
      expect(runtime.isDead, isFalse);
    },
  );

  test(
    'an unexpected current-generation exit fires teardown and is terminal',
    () async {
      final runtime = GenerationalRuntime();
      final gen1 = Completer<int>();
      runtime.watch(gen1.future);
      gen1.complete(137);
      expect(await runtime.unexpectedExit, 137);
      expect(
        runtime.isDead,
        isTrue,
        reason: 'no generation is running — a restart has nothing to kill',
      );
      await expectLater(
        runtime.restart(() async => Completer<int>().future),
        throwsA(predicate((e) => '$e'.contains('dead'))),
      );
    },
  );

  test('the NEW generation dying after a restart fires teardown', () async {
    final runtime = GenerationalRuntime();
    final gen1 = Completer<int>();
    runtime.watch(gen1.future);

    final gen2 = Completer<int>();
    await runtime.restart(() async {
      gen1.complete(0);
      return gen2.future;
    });
    gen2.complete(9);
    expect(await runtime.unexpectedExit, 9);
  });

  test('a stale generation completing late cannot fire teardown', () async {
    final runtime = GenerationalRuntime();
    final gen1 = Completer<int>();
    runtime.watch(gen1.future);

    final gen2 = Completer<int>();
    await runtime.restart(() async => gen2.future);
    // The old generation reports its exit only AFTER the restart installed gen2.
    gen1.complete(0);
    var fired = false;
    unawaited(runtime.unexpectedExit.then((_) => fired = true));
    await Future<void>.delayed(Duration.zero);
    expect(
      fired,
      isFalse,
      reason: 'a superseded generation is not the current one',
    );
  });

  test('a failed relaunch is terminal AND still tears down', () async {
    final runtime = GenerationalRuntime();
    runtime.watch(Completer<int>().future);

    await expectLater(
      runtime.restart(() async => throw StateError('no app came up')),
      throwsA(isA<StateError>()),
    );
    expect(runtime.isDead, isTrue);
    expect(
      await runtime.unexpectedExit,
      -1,
      reason: 'the daemon must still tear down',
    );

    await expectLater(
      runtime.restart(() async => Completer<int>().future),
      throwsA(predicate((e) => '$e'.contains('dead'))),
      reason: 'a dead runtime rejects further restarts by name',
    );
  });

  test('an overlapping restart is rejected — single-flight', () async {
    final runtime = GenerationalRuntime();
    runtime.watch(Completer<int>().future);

    final holdRelaunch = Completer<Future<int>>();
    final first = runtime.restart(() => holdRelaunch.future);
    await Future<void>.delayed(Duration.zero);
    expect(runtime.restartInFlight, isTrue);

    await expectLater(
      runtime.restart(() async => Completer<int>().future),
      throwsA(predicate((e) => '$e'.contains('already in flight'))),
    );

    holdRelaunch.complete(Completer<int>().future);
    await first;
    expect(runtime.restartInFlight, isFalse);
  });
}
