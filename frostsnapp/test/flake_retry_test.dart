import 'package:flutter_test/flutter_test.dart';

import '../test_driver/fsim.dart' show isTransientFlake, runWithRetry;

// Regression guard for the e2e startup-flake retry (sim-e2e-startup-flake-retry). On a cold-booted
// emulator the app janks at launch, `flutter run` drops the VM service, and the driver's first command
// dies with a SetFrameSync remote error / "Lost connection to device" — a transient infra flake, not a
// logic bug. The runner retries such failures from a fresh launch, but NOT genuine assertion failures.
void main() {
  group('isTransientFlake', () {
    test('a SetFrameSync remote error is transient', () {
      expect(
        isTransientFlake(
          'Unhandled exception:\n'
          'DriverError: Failed to fulfill SetFrameSync due to remote error',
        ),
        isTrue,
      );
    });

    test('a lost device connection is transient', () {
      expect(isTransientFlake('[app] Lost connection to device.'), isTrue);
    });

    // An uncaught State('x') prints as "Bad state: x" (NOT "StateError"), and the app shutting down
    // after the failure also emits a "Lost connection" line — so a real assertion must not be retried.
    test(
      'a real assertion (Bad state) is not retried even with a dropped connection',
      () {
        expect(
          isTransientFlake(
            '[app] Lost connection to device.\n'
            'Unhandled exception:\n'
            'Bad state: device never confirmed the security code',
          ),
          isFalse,
        );
      },
    );

    test('a matcher failure is not retried even with a dropped connection', () {
      expect(
        isTransientFlake(
          '[app] Lost connection to device.\n'
          'Expected: <true>\n  Actual: <false>',
        ),
        isFalse,
      );
    });

    test('a real assertion without a connection drop is not transient', () {
      expect(
        isTransientFlake('Bad state: tapped "X" but "Y" never appeared'),
        isFalse,
      );
    });

    test('clean output is not transient', () {
      expect(isTransientFlake('KEYGEN_DRIVE_OK: wallet created'), isFalse);
    });
  });

  group('runWithRetry', () {
    test(
      'retries a flaky attempt then succeeds, counting the retries',
      () async {
        var calls = 0;
        final (result, retries) = await runWithRetry<String>((n) async {
          calls++;
          return n < 2 ? 'flaky' : 'ok';
        }, (r) => r == 'flaky');
        expect(result, 'ok');
        expect(retries, 1);
        expect(calls, 2);
      },
    );

    test('gives up after maxAttempts, returning the last result', () async {
      var calls = 0;
      final (result, retries) = await runWithRetry<String>((n) async {
        calls++;
        return 'flaky';
      }, (r) => r == 'flaky');
      expect(result, 'flaky');
      expect(retries, 2); // 3 attempts → 2 retries
      expect(calls, 3);
    });

    test('does not retry a result that is not flaky', () async {
      var calls = 0;
      final (result, retries) = await runWithRetry<String>((n) async {
        calls++;
        return 'real-failure';
      }, (r) => r == 'flaky');
      expect(result, 'real-failure');
      expect(retries, 0);
      expect(calls, 1);
    });
  });
}
