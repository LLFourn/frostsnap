import 'dart:io';

import 'sim_harness.dart';

// A recording shows the devices beside the app, including one removed partway through, which must
// still read as removed rather than failing the capture.
//
// Android only; on a host there is no screen recording. Run:
// `./fsim test recording_devices --android`.
Future<void> main() async {
  await SimHarness.runScenario('recording_devices', (h) async {
    if (h.emulatorSerial == null) {
      stdout.writeln('RECORDING_DEVICES_SKIPPED: no emulator on a host run');
      return;
    }
    final clip = '${h.appDir.path}/devices.mp4';
    await h.record(clip, () async {
      await h.tap('Open navigation menu');
      await h
          .device(1)
          .swipe(120, 240, 120, 80, const Duration(milliseconds: 250));
      await Future<void>.delayed(const Duration(seconds: 1));
      await h.removeDevice(2);
      await Future<void>.delayed(const Duration(seconds: 1));
    });

    Future<({int width, int height})> size(String file) async {
      final probe = await Process.run('ffprobe', [
        '-v',
        'error',
        '-select_streams',
        'v:0',
        '-show_entries',
        'stream=width,height',
        '-of',
        'csv=p=0',
        file,
      ]);
      final [width, height] = (probe.stdout as String)
          .trim()
          .split(',')
          .map(int.parse)
          .toList();
      return (width: width, height: height);
    }

    final app = await size('$clip.app.mp4');
    final composite = await size(clip);
    // Two 240x280 devices at 2x, each under a 48 px label, fit beside a phone-height app unscaled.
    if (composite.height != app.height || composite.width != app.width + 480) {
      throw StateError(
        'expected the app (${app.width}x${app.height}) with a 480 px device panel beside it, '
        'got ${composite.width}x${composite.height}',
      );
    }
    stdout.writeln(
      'RECORDING_DEVICES_OK: ${composite.width}x${composite.height}, device 2 removed mid-recording',
    );
  }, deviceCount: 2);
}
