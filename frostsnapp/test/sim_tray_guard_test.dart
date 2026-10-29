import 'package:flutter_test/flutter_test.dart';

import 'package:frostsnap/sim_device_tray.dart' show guardedTrayMutation;

// The tray's mutation policy (fsim-app-restart): a failed mutation must BOTH surface
// its message and refresh the (evidently stale) list — an error without convergence
// leaves a wrong list behind the message; a silent refresh makes the failed action
// look like it worked. Process-independent: the policy is exercised with fakes,
// exactly like the provisionReadiness transaction tests.
void main() {
  test('a failing mutation surfaces the error AND refreshes', () async {
    final events = <String>[];
    await guardedTrayMutation(
      () => throw StateError('device 2 was removed'),
      onError: (message) => events.add('error: $message'),
      refresh: () async => events.add('refreshed'),
    );
    expect(events, hasLength(2));
    expect(events.first, contains('device 2 was removed'));
    expect(events.last, 'refreshed');
  });

  test('an async failure is caught the same way', () async {
    final events = <String>[];
    await guardedTrayMutation(
      () async => throw StateError('stale'),
      onError: (message) => events.add('error'),
      refresh: () async => events.add('refreshed'),
    );
    expect(events, ['error', 'refreshed']);
  });

  test('a successful mutation neither errors nor force-refreshes', () async {
    final events = <String>[];
    await guardedTrayMutation(
      () async {},
      onError: (message) => events.add('error'),
      refresh: () async => events.add('refreshed'),
    );
    expect(events, isEmpty);
  });
}
