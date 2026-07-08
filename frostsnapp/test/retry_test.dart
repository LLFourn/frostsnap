import 'package:flutter_test/flutter_test.dart';

import '../test_driver/fsim.dart' show runWithRetry;

// `fsim test` runs each test ONCE by default; `--retries N` opts into up to N extra attempts (for CI).
// There is no flake classification — a failed result is retried only because the caller asked for it. The
// pure control-flow helper is unit-tested here.
void main() {
  group('runWithRetry', () {
    test(
      'retries a failing attempt then succeeds, counting the retries',
      () async {
        var calls = 0;
        final (result, retries) = await runWithRetry<String>(
          (n) async {
            calls++;
            return n < 2 ? 'fail' : 'ok';
          },
          (r) => r == 'fail',
          maxAttempts: 3,
        );
        expect(result, 'ok');
        expect(retries, 1);
        expect(calls, 2);
      },
    );

    test('gives up after maxAttempts, returning the last result', () async {
      var calls = 0;
      final (result, retries) = await runWithRetry<String>(
        (n) async {
          calls++;
          return 'fail';
        },
        (r) => r == 'fail',
        maxAttempts: 3,
      );
      expect(result, 'fail');
      expect(retries, 2); // 3 attempts -> 2 retries
      expect(calls, 3);
    });

    test(
      'default (maxAttempts: 1) runs once and does NOT retry a failure',
      () async {
        var calls = 0;
        final (result, retries) = await runWithRetry<String>((n) async {
          calls++;
          return 'fail';
        }, (r) => r == 'fail');
        expect(result, 'fail');
        expect(retries, 0);
        expect(calls, 1);
      },
    );

    test('does not retry a result the predicate rejects', () async {
      var calls = 0;
      final (result, retries) = await runWithRetry<String>(
        (n) async {
          calls++;
          return 'ok';
        },
        (r) => r == 'fail',
        maxAttempts: 3,
      );
      expect(result, 'ok');
      expect(retries, 0);
      expect(calls, 1);
    });
  });
}
