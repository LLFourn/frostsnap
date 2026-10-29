import 'dart:io';

import 'sim_harness.dart';

// Owner for app_owner_exit_drive.dart: launches one desktop sim app the way a test does and idles,
// so the drive can SIGKILL this VM, the app's parent, without any Dart teardown running.
Future<void> main() async {
  final session = await Scenario.provisionAppInstance(
    index: 0,
    total: 1,
    slot:
        int.tryParse(Platform.environment['FROSTSNAP_SIM_WINDOW_SLOT'] ?? '') ??
        0,
    flutterDevice: Platform.environment['SIM_FLUTTER_DEVICE'] ?? 'macos',
    chain: null,
    deviceCount: 0,
  );
  stdout.writeln('OWNER_PID=$pid');
  await stdout.flush();
  await Future<void>.delayed(const Duration(hours: 1));
  await session.tearDown();
}
