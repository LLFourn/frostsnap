import 'dart:io';

import 'sim_harness.dart';

// Does fsim catch a layout that breaks at a large font? At Android font scale 2.0 the
// security-check-explainer team saw Choose threshold overflow ("Redundancy" and "Theft
// resistance" run together, RIGHT OVERFLOWED BY 11 PIXELS). Flutter reports an overflow as an
// error in a debug build, and the harness fails the command that follows any app error — so the
// screen, laid out at 2.0, must fail the scenario for that overflow and nothing else.
//
// The scale changes ON the screen, so any other screen's behaviour at 2.0 stays out of this case.
// At 1.0 the same screen raises nothing, which is checked first.
//
// Android only: whether a layout overflows depends on width as well as scale, and this is the
// width the team saw it at. Run: `./fsim test font_scale_overflow --android`.

/// The defect, as Flutter reports it on this emulator. Matched exactly: a different or additional
/// overflow is another failure, and must not keep this expectation alive once this one is fixed.
const _knownOverflow = 'A RenderFlex overflowed by 11 pixels on the right.';

final _overflows = ExpectedFailure(
  'Choose threshold lays out at font scale 2.0 without overflowing',
  fixedBy: 'the Choose threshold layout at large font scales',
);

Future<void> main() async {
  final device = Platform.environment['SIM_FLUTTER_DEVICE'] ?? 'macos';
  if (const {'macos', 'linux', 'windows'}.contains(device)) {
    stdout.writeln(
      '$simTestSkippedMarker: the overflow is at a phone width, on the emulator',
    );
    return;
  }
  await SimHarness.runScenario(
    'font_scale_overflow',
    deviceCount: 2,
    expectedToFail: _overflows,
    (h) async {
      await h.tapUntil(RegExp('Create a multi-sig wallet'), 'Wallet name');
      await h.enterText('Wallet name', 'Large');
      await h.tapUntil('Next', 'Device name 1');
      await h.enterText('Device name 1', 'Aaa');
      await h.enterText('Device name 2', 'Bbb');
      await h.tapUntil('Continue with 2 devices', 'Generate keys');
      await h.waitFor(RegExp('Redundancy'));
      // A measured 1.0, not the emulator's default: the screen must be clean at it, and anything
      // raised here fails the run outside the expectation.
      await h.setFontScale(1.0);
      if ((await h.textScale() - 1.0).abs() > 0.001) {
        throw StateError('the baseline is ${await h.textScale()}, not 1.0');
      }

      List<AppError> raised = const [];
      try {
        await h.setFontScale(2.0);
        await h.waitFor(RegExp('Redundancy'));
      } on AppErrorRaised catch (e) {
        raised = e.errors;
      }
      // One more command, outside the guard: it drains anything a LATER frame raised, which the
      // catch above never saw and which is not this defect.
      await h.waitFor(RegExp('Theft resistance'));
      // Identified outside the guard: only the known overflow is this defect. Anything else the
      // app raised — another overflow included — is a different failure and fails the run as one.
      final other = raised.where((e) => e.summary != _knownOverflow).toList();
      if (other.isNotEmpty) {
        throw StateError(
          'at font scale 2.0 Choose threshold raised more than the known overflow: '
          '${other.join('; ')}',
        );
      }
      stdout.writeln(
        'FONT_SCALE_OVERFLOW_OBSERVED: ${raised.map((e) => e.summary).join('; ')}',
      );

      final hit = await _overflows.guard(() async {
        if (raised.isNotEmpty) {
          throw StateError(
            'Choose threshold overflows at font scale 2.0: $_knownOverflow',
          );
        }
      });
      if (!hit) {
        stdout.writeln('FONT_SCALE_OVERFLOW_OK: Choose threshold fits at 2.0');
      }
    },
  );
}
