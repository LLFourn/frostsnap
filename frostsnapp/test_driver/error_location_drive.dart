import 'dart:io';

import 'sim_harness.dart';

// A Flutter error must say which widget raised it and where, or whoever reads the failure has to
// hunt for it. The desktop navigation rail overflows at font scale 2.0 — a real overflow, which
// Flutter reports with the widget that caused it; the failure must carry that widget's source file
// and line in the app.
//
// Desktop only: the rail is the wide layout. Run: `./fsim test error_location`.
Future<void> main() async {
  final device = Platform.environment['SIM_FLUTTER_DEVICE'] ?? 'macos';
  if (!const {'macos', 'linux', 'windows'}.contains(device)) {
    stdout.writeln(
      '$simTestSkippedMarker: the overflowing rail is the desktop layout',
    );
    return;
  }
  await SimHarness.runScenario('error_location', (h) async {
    List<AppError> raised;
    try {
      await h.setFontScale(2.0);
      await h.exists('Settings');
      throw StateError(
        'the rail did not overflow at 2.0, so this proves nothing',
      );
    } on AppErrorRaised catch (e) {
      raised = e.errors;
    }
    // Tied to the overflow itself, not to anywhere in the message (which also carries stacks).
    final location = raised
        .where((e) => e.summary.contains('overflowed'))
        .map((e) => RegExp(r'lib/[\w/]+\.dart:\d+').firstMatch(e.information))
        .nonNulls
        .firstOrNull;
    if (location == null) {
      throw StateError(
        'the overflow should name its widget\'s source location in lib/, got: ${raised.join('; ')}',
      );
    }
    await h.resetFontScale();
    stdout.writeln(
      'ERROR_LOCATION_OK: the overflow named ${location.group(0)}',
    );
  }, deviceCount: 0);
}
