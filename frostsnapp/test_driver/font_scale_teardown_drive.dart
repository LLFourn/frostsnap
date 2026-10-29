import 'dart:io';

import 'emulator.dart' show killEmulator;
import 'regtest.dart' show androidSdkRoot;
import 'sim_harness.dart';

// A session that changed the font scale and ends WITHOUT resetting it must hand a reused emulator
// back at its original scale — `fsim up` reuses a live emulator, so a scale left behind lands in
// the next session. The session here keeps its emulator, as a reused one would be kept, so the
// real teardown is what has to restore it.
//
// Android only. Run: `./fsim test font_scale_teardown --android`.
Future<void> main() async {
  final device = Platform.environment['SIM_FLUTTER_DEVICE'] ?? 'macos';
  if (const {'macos', 'linux', 'windows'}.contains(device)) {
    stdout.writeln(
      '$simTestSkippedMarker: needs an emulator that outlives its session',
    );
    return;
  }
  final sdk = androidSdkRoot();
  final session = await Scenario.provisionAppInstance(
    index: 0,
    total: 1,
    slot:
        int.tryParse(Platform.environment['FROSTSNAP_SIM_WINDOW_SLOT'] ?? '') ??
        0,
    flutterDevice: device,
    chain: null,
    deviceCount: 0,
    keepEmulator: true,
  );
  final serial = session.emulatorSerial;
  if (serial == null) {
    await session.tearDown();
    throw StateError('an android session came up without an emulator');
  }
  Future<double> systemScale() async {
    final read = await Process.run('$sdk/platform-tools/adb', [
      '-s',
      serial,
      'shell',
      'settings',
      'get',
      'system',
      'font_scale',
    ]);
    if (read.exitCode != 0) {
      throw StateError(
        'could not read the emulator font scale: ${read.stderr}',
      );
    }
    return fontScaleSetting((read.stdout as String).trim());
  }

  try {
    final before = await systemScale();
    await session.setFontScale(1.3);
    await session.tearDown();
    final after = await systemScale();
    if ((after - before).abs() > 0.001) {
      throw StateError(
        'teardown left the kept emulator at font scale $after, it was $before',
      );
    }
    stdout.writeln(
      'FONT_SCALE_TEARDOWN_OK: the kept emulator came back to font scale $before',
    );
  } finally {
    await killEmulator(sdk, serial);
  }
}
