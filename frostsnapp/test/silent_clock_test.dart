import 'package:flutter_test/flutter_test.dart';

import '../test_driver/silent_clock.dart';

// Pins the invariant the harness's load-tolerant waits rest on: a wait's
// budget is charged ONLY against inactivity observed during that wait —
// pre-existing silence cannot consume a fresh wait's budget — while fresh
// activity extends it no further than the hard cap.
void main() {
  final t0 = DateTime(2026, 1, 1, 12);
  const budget = Duration(seconds: 20);

  test('pre-wait silence does not consume a fresh wait\'s budget', () {
    final clock = SilentClock(started: t0, budget: budget);
    final longBefore = t0.subtract(const Duration(minutes: 10));
    expect(
      clock.expired(
        now: t0.add(const Duration(seconds: 19)),
        lastActivityAt: longBefore,
      ),
      isFalse,
    );
    expect(
      clock.expired(
        now: t0.add(const Duration(seconds: 20)),
        lastActivityAt: longBefore,
      ),
      isTrue,
    );
  });

  test('activity during the wait extends it', () {
    final clock = SilentClock(started: t0, budget: budget);
    final beat = t0.add(const Duration(seconds: 90));
    expect(
      clock.expired(
        now: t0.add(const Duration(seconds: 109)),
        lastActivityAt: beat,
      ),
      isFalse,
    );
    expect(
      clock.expired(
        now: t0.add(const Duration(seconds: 110)),
        lastActivityAt: beat,
      ),
      isTrue,
    );
  });

  test('the hard cap fires despite continuous activity', () {
    final clock = SilentClock(started: t0, budget: budget);
    final atCap = t0.add(budget * 6);
    expect(clock.expired(now: atCap, lastActivityAt: atCap), isTrue);
    expect(
      clock.expired(
        now: atCap.subtract(const Duration(seconds: 1)),
        lastActivityAt: atCap.subtract(const Duration(seconds: 1)),
      ),
      isFalse,
    );
  });

  test('total silence from the start expires exactly at the budget', () {
    final clock = SilentClock(started: t0, budget: budget);
    expect(
      clock.expired(
        now: t0.add(const Duration(seconds: 19)),
        lastActivityAt: t0,
      ),
      isFalse,
    );
    expect(clock.expired(now: t0.add(budget), lastActivityAt: t0), isTrue);
  });
}
