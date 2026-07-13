import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import '../test_driver/sim_harness.dart'
    show growFleetTo, provisionReadiness, readyOrDispose;

// Regression guard for runtime device-count delivery (sim-android-build-once, Task 3). A shared android
// APK can't bake a per-test SIM_DEVICE_COUNT and the emulator app can't read the host env, so the
// harness grows the fleet to the test's count over the app channel after launch. The growth must land
// at EXACTLY the requested count — a 3-device test that silently ran with 1 would still pass its early
// steps — and must never spin if add-device stops taking effect.
void main() {
  group('growFleetTo', () {
    test('grows a default-1 fleet up to the target', () async {
      var fleet = 1;
      final added = <int>[];
      await growFleetTo(3, () async => fleet, () async {
        fleet++;
        added.add(fleet);
        return fleet;
      });
      expect(fleet, 3);
      expect(added, [2, 3]); // 1 → 2 → 3: two hot-plugs
    });

    test(
      'is a no-op when the fleet already equals the target (the host case)',
      () async {
        var fleet = 2;
        var addCalls = 0;
        await growFleetTo(2, () async => fleet, () async {
          addCalls++;
          return ++fleet;
        });
        expect(addCalls, 0);
      },
    );

    test(
      'throws rather than spin when an add fails to grow the fleet',
      () async {
        const fleet = 1;
        await expectLater(
          growFleetTo(
            3,
            () async => fleet,
            () async => fleet,
          ), // add never grows
          throwsA(isA<StateError>()),
        );
      },
    );

    test(
      'throws when the final fleet overshoots the requested count',
      () async {
        var fleet = 1;
        await expectLater(
          growFleetTo(2, () async => fleet, () async {
            fleet += 2; // 1 → 3 when only 2 were asked for
            return fleet;
          }),
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
      'grows FIRST, then recognizes, and the return WAITS on recognition',
      () async {
        final events = <String>[];
        var fleet = 1;
        final recognition = Completer<void>();
        var done = false;
        // NOT awaited yet: the returned future must stay pending while recognition is held open — a
        // composition that fires recognize without awaiting it would return early and pass a
        // synchronous-callback version of this test.
        final pending = provisionReadiness(
          target: 3,
          count: () async => fleet,
          addOne: () async {
            events.add('add');
            return ++fleet;
          },
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

    test('growth failure disposes; recognition never runs', () async {
      final events = <String>[];
      Object? err;
      try {
        await provisionReadiness(
          target: 2,
          count: () async => 1,
          addOne: () async => 1, // no growth → growFleetTo throws
          recognize: () async => events.add('recognized'),
          dispose: () async => events.add('disposed'),
        );
      } catch (e) {
        err = e;
      }
      expect(events, ['disposed']);
      expect('$err', contains('did not grow'));
    });

    test('recognition failure disposes before rethrowing', () async {
      final events = <String>[];
      Object? err;
      try {
        await provisionReadiness(
          target: 1,
          count: () async => 1,
          addOne: () async => fail('no growth needed'),
          recognize: () async => throw StateError('never recognized'),
          dispose: () async => events.add('disposed'),
        );
      } catch (e) {
        err = e;
      }
      expect(events, ['disposed']);
      expect('$err', contains('never recognized'));
    });
  });

  // fsim-android-devices-count: the seam's failure-atomicity — a post-launch readiness failure must
  // dispose the half-provisioned session instead of orphaning the app/emulator/bridge.
  group('readyOrDispose', () {
    test('success returns the value and never disposes', () async {
      var disposed = 0;
      final v = await readyOrDispose(
        ready: () async => 7,
        dispose: () async => disposed++,
      );
      expect(v, 7);
      expect(disposed, 0);
    });

    test(
      'readiness failure disposes, then rethrows the ORIGINAL error',
      () async {
        var disposed = 0;
        Object? err;
        try {
          await readyOrDispose<void>(
            ready: () async => throw StateError('grow failed'),
            dispose: () async => disposed++,
          );
        } catch (e) {
          err = e;
        }
        expect(disposed, 1);
        expect('$err', contains('grow failed'));
      },
    );

    test(
      'a disposal failure is aggregated, never silently swallowed',
      () async {
        Object? err;
        try {
          await readyOrDispose<void>(
            ready: () async => throw StateError('grow failed'),
            dispose: () async => throw StateError('teardown also failed'),
          );
        } catch (e) {
          err = e;
        }
        expect('$err', contains('grow failed'));
        expect('$err', contains('teardown also failed'));
      },
    );
  });
}
