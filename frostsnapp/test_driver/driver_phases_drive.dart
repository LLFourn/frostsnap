import 'dart:io';

import 'sim_harness.dart';

// Phase attribution for driver-command failures (fsim-unsynchronized-input M1).
//
// One driver command is several round trips — disable frame sync, resolve a target, dispatch,
// restore frame sync — and FlutterDriver reports a timeout in any of them as the same
// `Timeout while executing <action>`. That is why a rotating set of tests can share a symptom
// without sharing a cause. Each case below FORCES one outcome and asserts the harness says which,
// so the attribution is pinned deterministically instead of only appearing during a flake.
//
// Run: `./fsim test driver_phases`.

Future<void> main() async {
  await SimHarness.runScenario('driver_phases', (h) async {
    // 1. No such label: resolved before dispatch, so this stays a fast label miss listing what IS
    //    on stage — it must never spend an action budget looking for something absent.
    final started = DateTime.now();
    final miss = await _failureOf(() => h.tap('NoSuchLabel_DriverPhaseProbe'));
    final missTook = DateTime.now().difference(started);
    if (!miss.contains('no on-stage label matches')) {
      throw StateError(
        'a missing label should read as a label miss, got: $miss',
      );
    }
    if (missTook > const Duration(seconds: 15)) {
      throw StateError(
        'a missing label took ${missTook.inSeconds}s — it should fail fast',
      );
    }

    // 2. Present but NOT actionable — the case that used to read as an inscrutable 20s timeout.
    //    The wallet's controls stay in the semantics tree behind a modal sheet, so the label
    //    resolves while hit-testing never reaches it. This is the erase_device failure, forced.
    await h.createWallet(name: 'PhaseProbe');
    await h.device(1).setConnected(true);
    if (!await h.exists(RegExp('Connected Devices'))) {
      await h.tap('Open navigation menu');
      await h.waitFor(RegExp('Connected Devices'));
    }
    await h.tap(RegExp('Connected Devices'));
    await h.waitFor(RegExp('Close'));
    final blocked = await _failureOf(() => h.tap(RegExp('^Send\$')));
    if (!blocked.contains('timed out in action') ||
        !blocked.contains('NOT hit-testable') ||
        !blocked.contains('a tap lands on')) {
      throw StateError(
        'a label behind a modal barrier should be reported as present-but-not-hit-testable, '
        'naming what the tap lands on instead — got: $blocked',
      );
    }

    // The barrier tap was a MUTATION that timed out, so the session is quarantined: its tap may
    // still land, and anything after it would be racing that. Observing polls in between (the
    // tapUntil-style checks above) must NOT have done this, or every test would quarantine.
    final refused = await _failureOf(() => h.tap('Receive'));
    if (!refused.contains('refused') || !refused.contains('STILL RUNNING')) {
      throw StateError(
        'a timed-out mutation should quarantine the session — got: $refused',
      );
    }

    stdout.writeln(
      'DRIVER_PHASES_OK: a missing label stays a fast label miss (${missTook.inMilliseconds}ms), '
      'a RegExp-targeted barrier is named by what the tap lands on, and the timed-out mutation '
      'quarantined the session while observing polls did not',
    );
  }, deviceCount: 1);

  // A SECOND session, because the first is quarantined by design: its barrier tap timed out while
  // mutating, so it may still land and nothing after it can be trusted. That boundary is per
  // AppSession, which this both relies on and demonstrates.
  await SimHarness.runScenario('driver_phases_stalled', (h) async {
    // The app itself stops answering. Only forceable with a deliberate stall, and it must read as
    // contention rather than as a fact about the target — the opposite conclusion to the barrier
    // case, drawn from the same bare "Timeout while executing tap".
    // Longer than the action budget, or the tap would simply land once the app wakes.
    h.stallApp(const Duration(seconds: 26));
    await Future<void>.delayed(const Duration(seconds: 1));
    final stalled = await _failureOf(
      () => h.tap(RegExp('Create a multi-sig wallet')),
    );
    if (!stalled.contains('did not answer') &&
        !stalled.contains('contention')) {
      throw StateError(
        'a stalled app should read as contention, not as a fact about the target — got: $stalled',
      );
    }
    stdout.writeln(
      'DRIVER_PHASES_STALLED_OK: an unresponsive app reads as contention, not as a target fact',
    );
  }, deviceCount: 1);

  // A stray marked on the APP CHANNEL must poison the whole session, not just the channel that
  // found it — and it must do so LOUDLY on every normal surface. The earlier version marked without
  // enforcing, so later app-channel work raced the still-running handler; and because the boolean
  // predicates catch everything, a refusal that did fire came back as `false` and reported a present
  // label as absent. Both are silent-wrong-answer failures, which is why all four surfaces are
  // asserted here rather than just the one that happened to be fixed.
  await SimHarness.runScenario('driver_phases_quarantine', (h) async {
    // Force a MUTATING app-channel call to be abandoned: the app cannot answer while stalled, so
    // addDevice times out and marks the stray. (Stalling is itself detached — it marks nothing.)
    h.stallApp(const Duration(seconds: 26));
    await Future<void>.delayed(const Duration(seconds: 1));
    final marked = await _failureOf(() => h.addDevice());
    if (!marked.contains('timed out') && !marked.contains('unanswered')) {
      throw StateError(
        'expected the stalled mutation to time out, got: $marked',
      );
    }

    // All four normal surfaces must now refuse, with the same explanation. These are instant —
    // the refusal happens before anything is sent, so a stalled app cannot mask it.
    final refusals = <String, String>{
      'app mutation': await _failureOf(() => h.addDevice()),
      'app observation': await _failureOf(() => h.deviceNumbers()),
      'driver action': await _failureOf(() => h.tap('Create wallet')),
      'driver predicate': await _failureOf(() => h.exists('Create wallet')),
      // ABSENT targets specifically: the label classifier rewrites a failure whose finder is not
      // on stage into "no on-stage label matches", which would turn the refusal into a false fact
      // about the target — the exact substitution quarantine exists to prevent.
      'driver action, absent target': await _failureOf(
        () => h.tap('NoSuchLabel_QuarantineProbe'),
      ),
      'driver wait, absent target': await _failureOf(
        () => h.waitFor('NoSuchLabel_QuarantineProbe'),
      ),
      'driver predicate, absent target': await _failureOf(
        () => h.exists('NoSuchLabel_QuarantineProbe'),
      ),
    };
    refusals.forEach((surface, message) {
      if (!message.contains('refused') || !message.contains('STILL RUNNING')) {
        throw StateError('$surface should have been refused, got: $message');
      }
    });

    // ...while failure diagnostics stay available, or the session could not report on itself.
    // Wait out the stall first: this asserts the QUARANTINE does not block capture, not that a
    // stalled app can answer.
    await Future<void>.delayed(const Duration(seconds: 27));
    final labels = await h.semantics().labels();
    if (labels.isEmpty) {
      throw StateError('diagnostic capture must survive a quarantine');
    }
    await h.screenshot('quarantined');

    stdout.writeln(
      'DRIVER_PHASES_QUARANTINE_OK: an app-channel stray refused every surface '
      '(${refusals.keys.join(", ")}) while diagnostic capture stayed available',
    );
  }, deviceCount: 0);

  // The AUTOMATIC artifact path, not just the calls it makes. Failure capture reads device numbers
  // and framebuffers, and those became gated observations — so a quarantined scenario threw inside
  // the extras and skipped writing error.txt entirely, losing the primary evidence for exactly the
  // failures that need it most. `runScenario` captures and then rethrows, so a deliberate failure
  // here exercises the real path.
  await _capturesEvidenceWhileQuarantined();

  // Frame sync is APP-SIDE GLOBAL state, so anything that restores it mid-action disables the

  // Frame sync is APP-SIDE GLOBAL state, so anything that restores it mid-action disables the
  // harness's own `runUnsynchronized` without saying so. `tapTooltip` reads the semantics snapshot
  // before it taps, and that nested request used to restore frame sync in a `finally` — after
  // which `waitForElement` waits for `transientCallbackCount == 0`, which a running animation
  // never reaches. That is the real erase_device failure: `tapTooltip("More")` burned the whole
  // 20s action budget under `--jobs 18` with the wallet confetti still on screen, and passed solo
  // only because the confetti had finished first. Timing decided it, so an animation with a
  // duration the test controls is what pins it.
  await SimHarness.runScenario('driver_phases_animating', (h) async {
    await h.createWallet(name: 'AnimProbe');
    await h.waitFor(RegExp('Receive'));

    // Must outlast the 20s the broken path spends timing out, or the animation would stop first
    // and let the tap through for the wrong reason.
    await h.animateApp(const Duration(seconds: 30));
    final started = DateTime.now();
    await h.tapTooltip('More');
    await h.waitFor(RegExp('View wallet access structure'));
    final took = DateTime.now().difference(started);
    if (took > const Duration(seconds: 10)) {
      throw StateError(
        'tapTooltip took ${took.inSeconds}s while the app was animating — frame sync was left '
        'enabled by the snapshot read nested inside the action',
      );
    }

    stdout.writeln(
      'DRIVER_PHASES_ANIMATING_OK: a data request nested inside an action no longer restores '
      'frame sync — the tap landed in ${took.inMilliseconds}ms with the app still animating',
    );
  }, deviceCount: 1);
}

/// A quarantined scenario that FAILS must still write its primary error file. Asserts against the
/// real capture path, then removes what this deliberate failure wrote so a passing run leaves no
/// error file behind to confuse the next reader of the artifacts directory.
Future<void> _capturesEvidenceWhileQuarantined() async {
  const name = 'driver_phases_capture';
  const marker = 'deliberate failure: exercising capture while quarantined';
  final base = Platform.environment['SIM_TEST_ARTIFACTS_DIR'];
  final dir = Directory(
    base == null || base.isEmpty ? 'build/sim-failures/$name' : base,
  );
  final before = dir.existsSync()
      ? {for (final e in dir.listSync()) e.path}
      : <String>{};

  try {
    await SimHarness.runScenario(name, (h) async {
      h.stallApp(const Duration(seconds: 22));
      await Future<void>.delayed(const Duration(seconds: 1));
      await _failureOf(() => h.addDevice());
      throw StateError(marker);
    }, deviceCount: 0);
    throw StateError('the capture scenario was supposed to fail');
  } catch (e) {
    if (!'$e'.contains(marker)) rethrow;
  }

  // error.txt, or scenario-error.txt when the runner already owns one for this test.
  final written = dir
      .listSync()
      .whereType<File>()
      .where((f) => !before.contains(f.path))
      .where((f) => f.path.endsWith('error.txt'))
      .toList();
  if (written.isEmpty) {
    throw StateError(
      'a quarantined failure wrote no error file to ${dir.path} — the primary evidence for a '
      'poisoned session is exactly what must survive',
    );
  }
  if (!written.any((f) => f.readAsStringSync().contains(marker))) {
    throw StateError('the error file does not contain the scenario error');
  }
  for (final f in written) {
    f.deleteSync();
  }
  stdout.writeln(
    'DRIVER_PHASES_CAPTURE_OK: a quarantined scenario still wrote its error file',
  );
}

/// Run [action], expecting failure, and return the message.
Future<String> _failureOf(Future<void> Function() action) async {
  try {
    await action();
  } catch (e) {
    return '$e';
  }
  throw StateError('expected a failure, got none');
}
