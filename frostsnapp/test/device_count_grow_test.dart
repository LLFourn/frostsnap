import 'package:flutter_test/flutter_test.dart';

import '../test_driver/sim_harness.dart' show growFleetTo;

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
}
