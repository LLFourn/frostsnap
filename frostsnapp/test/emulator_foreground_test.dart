import 'package:flutter_test/flutter_test.dart';

import '../test_driver/driver_phase.dart';
import '../test_driver/emulator_foreground.dart';

// A locked or sleeping emulator makes every driver command time out, and the timeout used to read
// like the app hanging on an animation. These pin that the dumps are read correctly and that the
// finding LEADS the failure it explains.
void main() {
  const awake = '  mWakefulness=Awake\n  mWakefulnessChanging=false\n';
  const asleep = '  mWakefulness=Asleep\n';
  const appFocused =
      '  mCurrentFocus=Window{9a1b2c3 u0 com.frostsnap/com.frostsnap.MainActivity}\n'
      '    isKeyguardShowing=false\n';
  const locked =
      '  mCurrentFocus=Window{f61cf0e u0 NotificationShade}\n'
      '    isKeyguardShowing=true\n';

  test('an awake, unlocked, focused app has nothing to report', () {
    expect(foregroundFinding(power: awake, window: appFocused), isNull);
  });

  test('a locked emulator says so, and says what has focus instead', () {
    final finding = foregroundFinding(power: awake, window: locked)!;
    expect(finding, contains('locked'));
    expect(finding, contains('NotificationShade'));
    expect(finding, contains('no frames'));
  });

  test('a sleeping screen says so', () {
    expect(
      foregroundFinding(power: asleep, window: appFocused),
      contains('asleep'),
    );
  });

  test('before the app launches, focus is not asked about', () {
    const launcher =
        '  mCurrentFocus=Window{1 u0 com.google.android.apps.nexuslauncher}\n'
        '    isKeyguardShowing=false\n';
    expect(
      foregroundFinding(power: awake, window: launcher, package: null),
      isNull,
    );
  });

  test('the finding leads a refusal', () {
    const finding = 'the emulator is not showing the app — it is locked';
    final refusal = SessionQuarantined(
      strayVerb: 'tapTooltip("More")',
      strayPhase: DriverPhase.action,
      refusedVerb: 'exists("Receive")',
      waited: const Duration(seconds: 3),
    ).withEnvironment(finding);
    expect('$refusal', startsWith(finding));
  });
}
