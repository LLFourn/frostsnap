import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import '../test_driver/sim_harness.dart'
    show convergeFleetTo, provisionReadiness, readyOrDispose;

// Regression guard for runtime device-count delivery (sim-android-build-once, Task 3;
// fsim-app-restart made it two-directional). A shared android APK can't bake a per-test
// SIM_DEVICE_COUNT and the emulator app can't read the host env, so the harness CONVERGES the
// fleet to the test's count over the app channel after launch — adding when under, removing the
// newest devices when over (that is how `deviceCount: 0` works on android, whose APK launches with
// one baked-in device). Convergence must land at EXACTLY the requested count — a 3-device test
// that silently ran with 1 would still pass its early steps — and must never spin if an
// add/remove stops taking effect.
void main() {
  group('convergeFleetTo', () {
    test('grows a default-1 fleet up to the target', () async {
      final fleet = <int>[1];
      final added = <int>[];
      await convergeFleetTo(3, () async => List.of(fleet), () async {
        final n = fleet.length + 1;
        fleet.add(n);
        added.add(n);
        return n;
      }, (n) async => fail('growth must not remove'));
      expect(fleet, [1, 2, 3]);
      expect(added, [2, 3]); // 1 → 2 → 3: two hot-plugs
    });

    test(
      'shrinks to the target by removing the NEWEST devices first',
      () async {
        final fleet = <int>[1, 2, 3];
        final removed = <int>[];
        await convergeFleetTo(
          1,
          () async => List.of(fleet),
          () async => fail('shrink must not add'),
          (n) async {
            removed.add(n);
            fleet.remove(n);
          },
        );
        expect(fleet, [1], reason: 'the launch device survives');
        expect(removed, [3, 2], reason: 'newest numbers go first');
      },
    );

    test('shrinks to ZERO — the empty-fleet session', () async {
      final fleet = <int>[1];
      await convergeFleetTo(
        0,
        () async => List.of(fleet),
        () async => fail('shrink must not add'),
        (n) async => fleet.remove(n),
      );
      expect(fleet, isEmpty);
    });

    test(
      'is a no-op when the fleet already equals the target (the host case)',
      () async {
        var addCalls = 0;
        await convergeFleetTo(2, () async => [1, 2], () async {
          addCalls++;
          return 3;
        }, (n) async => fail('no removal needed'));
        expect(addCalls, 0);
      },
    );

    test(
      'throws rather than spin when an add fails to grow the fleet',
      () async {
        await expectLater(
          convergeFleetTo(
            3,
            () async => [1],
            () async => 1, // add never grows
            (n) async {},
          ),
          throwsA(isA<StateError>()),
        );
      },
    );

    test(
      'throws rather than spin when a remove fails to shrink the fleet',
      () async {
        await expectLater(
          convergeFleetTo(
            1,
            () async => [1, 2],
            () async => fail('shrink must not add'),
            (n) async {}, // remove never shrinks
          ),
          throwsA(isA<StateError>()),
        );
      },
    );
  });

  // fsim-android-devices-count: the READINESS TRANSACTION — the exact composition the seam runs.
  // Ingredient tests alone stay green if the seam drops recognition, reverses ordering, or loses
  // atomicity; these guard the contract itself.
  group('provisionReadiness', () {
    test(
      'converges FIRST, then recognizes, and the return WAITS on recognition',
      () async {
        final events = <String>[];
        final fleet = <int>[1];
        final recognition = Completer<void>();
        var done = false;
        // NOT awaited yet: the returned future must stay pending while recognition is held open — a
        // composition that fires recognize without awaiting it would return early and pass a
        // synchronous-callback version of this test.
        final pending = provisionReadiness(
          target: 3,
          numbers: () async => List.of(fleet),
          addOne: () async {
            events.add('add');
            final n = fleet.length + 1;
            fleet.add(n);
            return n;
          },
          removeOne: (n) async => fail('growth must not remove'),
          recognize: () {
            events.add('recognize started');
            return recognition.future;
          },
          dispose: () async => fail('success must not dispose'),
        ).then((_) => done = true);
        await Future<void>.delayed(Duration.zero);
        expect(events, ['add', 'add', 'recognize started']);
        expect(
          done,
          isFalse,
          reason: 'must not return while recognition is pending',
        );
        recognition.complete();
        await pending;
        expect(done, isTrue);
      },
    );

    test('convergence failure disposes; recognition never runs', () async {
      final events = <String>[];
      Object? err;
      try {
        await provisionReadiness(
          target: 2,
          numbers: () async => [1],
          addOne: () async => 1, // no growth → convergeFleetTo throws
          removeOne: (n) async {},
          recognize: () async => events.add('recognized'),
          dispose: () async => events.add('disposed'),
        );
      } catch (e) {
        err = e;
      }
      expect(events, ['disposed']);
      expect('$err', contains('stuck'));
    });

    test('recognition failure disposes before rethrowing', () async {
      final events = <String>[];
      Object? err;
      try {
        await provisionReadiness(
          target: 1,
          numbers: () async => [1],
          addOne: () async => fail('no growth needed'),
          removeOne: (n) async => fail('no removal needed'),
          recognize: () async => throw StateError('never recognized'),
          dispose: () async => events.add('disposed'),
        );
      } catch (e) {
        err = e;
      }
      expect(events, ['disposed']);
      expect('$err', contains('never recognized'));
    });

    test('readyOrDispose aggregates a disposal failure', () async {
      Object? err;
      try {
        await readyOrDispose<void>(
          ready: () async => throw StateError('ready failed'),
          dispose: () async => throw StateError('dispose failed too'),
        );
      } catch (e) {
        err = e;
      }
      expect('$err', contains('ready failed'));
      expect('$err', contains('dispose failed too'));
    });
  });
}
