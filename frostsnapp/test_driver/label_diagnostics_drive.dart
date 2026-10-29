import 'dart:io';

import 'sim_harness.dart';

// fsim-label-diagnostics: the committed negative-path proof that tap/waitFor actually route through
// the failure CLASSIFIER — pure formatter tests can't show the wiring. The intentional failures are
// CAUGHT and their messages asserted, so the suite stays green. Run: `./fsim test label_diagnostics`.
Future<void> main() async {
  await AppSession.runScenario('label-diagnostics', (h) async {
    // The home CTA card merges title+subtitle into ONE label — the exact-String tap that burned
    // hours in the PR-505 recording effort. It must now name the merged label and suggest RegExp,
    // and never surface as "Lost connection".
    Object? miss;
    try {
      await h.tap('Create a multi-sig wallet');
    } catch (e) {
      miss = e;
    }
    final missMsg = '$miss';
    if (!missMsg.contains('no EXACT label match') ||
        !missMsg.contains('Set up a secure wallet') ||
        !missMsg.contains('RegExp') ||
        missMsg.contains('Lost connection')) {
      throw StateError('label-miss diagnostic wrong, got: $missMsg');
    }

    // A plain nothing-matches miss lists what IS on stage.
    Object? absent;
    try {
      await h.waitFor(
        'nonexistent-xyz-123',
        timeout: const Duration(seconds: 3),
      );
    } catch (e) {
      absent = e;
    }
    final absentMsg = '$absent';
    if (!absentMsg.contains('no on-stage label matches') ||
        !absentMsg.contains('Restore wallet') ||
        absentMsg.contains('Lost connection')) {
      throw StateError('waitFor listing diagnostic wrong, got: $absentMsg');
    }

    stdout.writeln(
      'LABEL_DIAGNOSTICS_OK: misses are descriptive, never "Lost connection"',
    );
  });
}
