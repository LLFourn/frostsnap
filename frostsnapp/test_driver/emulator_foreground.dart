// Whether the app can render on the emulator at all. A driver command waits on frames, and an app
// behind the keyguard, on a sleeping screen, or under another window renders none — so every
// command times out and the failure reads like the app hanging. These say which it is.

/// The app package the sim launches on Android.
const simAppPackage = 'com.frostsnap';

/// Why the app on this emulator cannot render, from `dumpsys power` and `dumpsys window`, or null
/// when it is the awake, unlocked, focused window. A null [package] skips the focus check, for
/// before the app has launched.
String? foregroundFinding({
  required String power,
  required String window,
  String? package = simAppPackage,
}) {
  final problems = <String>[];
  final wakefulness = RegExp(r'mWakefulness=(\w+)').firstMatch(power)?.group(1);
  if (wakefulness != null && wakefulness != 'Awake') {
    problems.add('its screen is ${wakefulness.toLowerCase()}');
  }
  if (window.contains('isKeyguardShowing=true')) {
    problems.add('it is locked (the keyguard is showing)');
  }
  final focus = RegExp(
    r'mCurrentFocus=(.*)',
  ).firstMatch(window)?.group(1)?.trim();
  if (package != null && focus != null && !focus.contains(package)) {
    problems.add('another window has focus: $focus');
  }
  if (problems.isEmpty) return null;
  return 'the emulator is not showing the app — ${problems.join('; ')}. The app renders no frames '
      'until it is in front, so driver commands wait on it and time out. Unlock it (PIN 0000) or '
      're-run `fsim up`, which unlocks it';
}
