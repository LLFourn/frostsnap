import 'dart:io';

import 'sim_harness.dart';

// A scenario can run at a font scale, and give it back. Asserted from the app's own MediaQuery —
// what its screens actually lay out with — not from the setting that was written. On Android the
// emulator's own setting must come back exactly as it was, not as an assumed 1.0.
//
// Scales below the ones that overflow real screens: this pins the verb, and an overflow at 2.0
// (the desktop navigation rail overflows by 61px) would fail it for a layout reason instead.
//
// Run: `./fsim test font_scale` (and with `--android`).
Future<void> main() async {
  await SimHarness.runScenario('font_scale', (h) async {
    final starting = await h.textScale();
    final serial = h.emulatorSerial;
    final systemBefore = serial == null
        ? null
        : (await h.adb([
            'shell',
            'settings',
            'get',
            'system',
            'font_scale',
          ])).trim();

    await h.setFontScale(1.3);
    if (!_near(await h.textScale(), 1.3)) {
      throw StateError('the app lays out at ${await h.textScale()}, not 1.3');
    }
    // Twice, so a second change does not overwrite the value captured before the first.
    await h.setFontScale(1.2);

    await h.resetFontScale();
    final after = await h.textScale();
    if (!_near(after, starting)) {
      throw StateError('reset left the app at $after, it started at $starting');
    }
    if (systemBefore case final before?) {
      final systemAfter = (await h.adb([
        'shell',
        'settings',
        'get',
        'system',
        'font_scale',
      ])).trim();
      // Compared as scales, not strings: once font_scale has been written, Android reads an unset
      // value back as 1.0 (seen: `settings delete` reports the row gone, `get` then says 1.0).
      if (!_near(fontScaleSetting(systemAfter), fontScaleSetting(before))) {
        throw StateError(
          'the emulator setting came back as $systemAfter, it was $systemBefore',
        );
      }
    }

    stdout.writeln(
      'FONT_SCALE_OK: the app laid out at 1.3 and came back to $starting'
      '${serial == null ? '' : ', with the emulator setting restored to $systemBefore'}',
    );
  });
}

/// Android hands the system setting to Flutter as a float32, so 1.3 arrives as 1.2999999523.
bool _near(double a, double b) => (a - b).abs() < 0.001;
