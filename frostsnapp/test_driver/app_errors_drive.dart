import 'dart:io';

import 'sim_harness.dart';

// A Flutter error must fail the test that caused it (fsim-no-hidden-flutter-errors M1/M2).
//
// Before this, app errors were only `[app:err]` stderr text — capped at 400 lines, never asserted
// on, read by a human only when some OTHER failure produced an artifact. A red screen, a
// `setState() after dispose()` or an assertion in `build` left the app running and the scenario
// green. Each case here provokes one real error and asserts the harness turns it into a failure.
//
// Run: `./fsim test app_errors`.

Future<void> main() async {
  await SimHarness.runScenario('app_errors', (h) async {
    // 1. A throw inside `build` — the RED SCREEN. Flutter reports it through FlutterError.onError
    //    and then swaps the subtree for an ErrorWidget, so the app keeps running.
    final build = await _failureOf(() async {
      await h.provokeBuildError();
      // Any command after it drains and attributes; the provoke itself may already carry it.
      await h.exists('Wallets');
    });
    if (!build.contains('raised') ||
        !build.contains('deliberate build failure')) {
      throw StateError('a build failure must fail the scenario — got: $build');
    }
    // ONE logical error, not two: the ErrorWidget renders the same failure onError already
    // recorded, and must not double-count it.
    if (RegExp('deliberate build failure').allMatches(build).length > 1 ||
        build.contains('2 Flutter error')) {
      throw StateError(
        'one build throw must produce ONE captured error — got: $build',
      );
    }
    // ...and the wrecked subtree is targetable rather than merely red.
    if (!await h.exists(simErrorWidgetLabel)) {
      throw StateError('a rendered error widget must carry a findable label');
    }
    await h.clearProvokedError();

    // 2. A framework error that renders nothing — reported through FlutterError.onError alone.
    final framework = await _failureOf(() async {
      await h.provokeFrameworkError();
      await h.exists('Wallets');
    });
    if (!framework.contains('deliberate framework failure')) {
      throw StateError(
        'a framework error must fail the scenario — got: $framework',
      );
    }

    // 3. An async throw escaping its zone, which no awaiting caller would ever see.
    final async = await _failureOf(() async {
      await h.provokeAsyncError();
      // The zone delivers it on its own schedule, so POLL for the drain to notice rather than
      // sleeping a guessed interval: the loop ends the moment the error is attributed.
      final by = DateTime.now().add(const Duration(seconds: 10));
      while (DateTime.now().isBefore(by)) {
        await h.exists('Wallets');
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    });
    if (!async.contains('deliberate async failure')) {
      throw StateError(
        'an uncaught async error must fail the scenario — got: $async',
      );
    }

    // 4. An ALLOWED error is consumed by its scope, and the session carries on.
    await h.expectAppErrors('deliberate framework failure', () async {
      await h.provokeFrameworkError();
      await h.exists('Wallets');
    });

    // 5. An allowance that never fires FAILS — otherwise a stale allowance silently suppresses
    //    real errors for as long as it stays in the code.
    final stale = await _failureOf(
      () => h.expectAppErrors('never happens in this scenario', () async {
        await h.exists('Wallets');
      }),
    );
    if (!stale.contains('stale')) {
      throw StateError('an unmatched allowance must fail — got: $stale');
    }

    // 6. An error the allowance does NOT match still fails inside its scope.
    final unmatched = await _failureOf(
      () => h.expectAppErrors('some other error entirely', () async {
        await h.provokeFrameworkError();
        await h.exists('Wallets');
      }),
    );
    if (!unmatched.contains('deliberate framework failure')) {
      throw StateError(
        'an error outside the allowance must still fail — got: $unmatched',
      );
    }

    // 7. A DRIVER-CAUSED red widget must keep the app's own explanation. The tap destroys its own
    //    target, so the next driver command finds no such label — and finder diagnosis would
    //    happily rewrite "the app threw" into "no on-stage label matches", dropping the summary and
    //    stack. The app error must win.
    await h.armTappableBuildError();
    // The tap SUCCEEDS, then the rebuild it triggered throws and replaces the target. So this
    // command's own drain raises the app error while its finder has just ceased to exist — which
    // is exactly when diagnosis would rewrite it as a label miss.
    final viaDriver = await _failureOf(() => h.tap('ProvokeBuildTarget'));
    if (!viaDriver.contains('deliberate build failure')) {
      throw StateError(
        'a driver-caused build failure must keep the app error, not be rewritten as a label '
        'miss — got: $viaDriver',
      );
    }
    if (viaDriver.contains('no on-stage label matches')) {
      throw StateError(
        'the app error was rewritten as a label miss: $viaDriver',
      );
    }
    if (!viaDriver.contains('#0 ')) {
      throw StateError('the app error lost its stack: $viaDriver');
    }
    await h.clearProvokedError();

    stdout.writeln(
      'APP_ERRORS_OK: a build failure (red widget, counted once and findable), a framework error '
      'and an uncaught async error each fail the scenario; an allowance consumes only what it '
      'matches, a stale allowance fails, and a driver-caused red widget keeps its summary and '
      'stack instead of being rewritten as a label miss',
    );
  }, deviceCount: 0);

  // A restart must not LAUNDER errors. Its own session, because a restart that fails marks the
  // runtime dead by design — nothing can use the session afterwards, which is the correct guard and
  // not something to work around.
  await SimHarness.runScenario('app_errors_before_restart', (h) async {
    // Timed to land after the last command's own drain, so only the restart path can catch it.
    await h.provokeAsyncError(after: const Duration(milliseconds: 200));
    await Future<void>.delayed(const Duration(milliseconds: 600));

    // WHICH drain catches it is not the point and must not be asserted: restartApp reads the device
    // counter inside its transaction, so that command's drain usually gets there first, and the
    // explicit pre-kill drain covers the window after it. Either way the restart must FAIL carrying
    // the error rather than complete over it.
    final swallowed = await _failureOf(() => h.restartApp());
    if (!swallowed.contains('deliberate async failure')) {
      throw StateError(
        'an error raised before a restart must not be swallowed by it — got: $swallowed',
      );
    }
    stdout.writeln(
      'APP_ERRORS_BEFORE_RESTART_OK: an error from the outgoing app failed the restart instead of '
      'dying with the process',
    );
  }, deviceCount: 0);

  // DETECTION MUST SURVIVE A RESTART. The app is killed and relaunched, so the hooks exist again
  // only because the new process runs `install()`. If that ever stopped happening the drain would
  // return empty forever and every scenario would go green over a throwing app — precisely the
  // state this plan exists to end. Assumed working is not good enough; it is asserted.
  await SimHarness.runScenario('app_errors_after_restart', (h) async {
    // CONSUME an error first, so the cursor is advanced past ids the NEW generation will reuse.
    // Ids restart at 1 in every process; a cursor carried across the restart would prune the new
    // generation's first errors and report nothing — silent loss exactly where a reset hides it.
    await h.expectAppErrors('deliberate framework failure', () async {
      await h.provokeFrameworkError();
      await h.exists('Wallets');
    });

    await h.restartApp();

    final build = await _failureOf(() async {
      await h.provokeBuildError();
      await h.exists('Wallets');
    });
    if (!build.contains('deliberate build failure')) {
      throw StateError(
        'a build error must still be caught after a restart — got: $build',
      );
    }
    await h.clearProvokedError();

    final framework = await _failureOf(() => h.provokeFrameworkError());
    if (!framework.contains('deliberate framework failure')) {
      throw StateError(
        'a framework error must still be caught after a restart — got: $framework',
      );
    }

    stdout.writeln(
      'APP_ERRORS_AFTER_RESTART_OK: both sources are still detected in the new generation, whose '
      'ids restart at 1 below an already-advanced cursor',
    );
  }, deviceCount: 0);

  // The FIRST defect this detector caught, kept as a test so it cannot come back silently.
  // `_OffCard`/`_ChainCard` held a live SimDevice and called `number()`/`id()` — FRB calls into
  // Rust — from inside `build`. Once a device is removed those throw `device N was removed`, and a
  // throw during build becomes a red ErrorWidget. The tray flashed one on every removal and no test
  // could see it, because the app simply carried on.
  await SimHarness.runScenario('app_errors_device_removal', (h) async {
    // Remove a CONNECTED device, whose chain card is certainly on screen — no dependence on which
    // tray section is rendered or on the layout. The tray holds that handle for up to one poll
    // interval afterwards, which is the window where the old code threw.
    await h.waitFor(RegExp('Device 2'));
    await h.removeDevice(2);
    await h.waitForAbsent(RegExp('Device 2'));

    stdout.writeln(
      'APP_ERRORS_DEVICE_REMOVAL_OK: removing a device with its card on screen raised no Flutter '
      'error — identity comes from a snapshot, and a dead frame stream closes instead of throwing',
    );
  }, deviceCount: 2);

  // An app error must WIN the report without costing the quarantine. A mutating command abandoned
  // while an error is pending should surface the app error — and the session must still be poisoned,
  // because that abandoned tap may yet land.
  await SimHarness.runScenario('app_errors_quarantine_order', (h) async {
    await h.showDuplicateTargets('QuarantineProbe', 1);
    // Comfortably longer than the action budget, so the tap is ABANDONED rather than merely slow.
    await h.blockDuplicateTargetTap(const Duration(seconds: 40));
    // ASYNC and delayed: a framework error is drained by the very request that provokes it, so it
    // would be reported and gone before the tap even starts. This one lands while the tap is
    // blocked, which is what leaves it pending when the tap gives up.
    await h.provokeAsyncError(after: const Duration(seconds: 2));

    // A PLAIN tap, carrying no caller deadline. With one spent (as tapWhenUnique's would be) the
    // drain is correctly skipped and the error is reported by the NEXT one — deferred, not lost.
    // Here there is time, so the app error must win this command's own report.
    final first = await _failureOf(() => h.tap('QuarantineProbe'));
    // The app error is the better explanation, so it is what surfaces.
    if (!first.contains('deliberate async failure')) {
      throw StateError(
        'the pending app error should be reported — got: $first',
      );
    }

    // ...and the abandoned mutation was still recorded, so the next operation is refused.
    final next = await _failureOf(() => h.exists('Wallets'));
    if (!next.contains('refused') || !next.contains('STILL RUNNING')) {
      throw StateError(
        'an app error must not cost the quarantine of the command it interrupted — got: $next',
      );
    }

    stdout.writeln(
      'APP_ERRORS_QUARANTINE_ORDER_OK: the app error was reported AND the abandoned mutation still '
      'quarantined the session',
    );
  }, deviceCount: 0);

  await _trailingErrorStillFails();
}

/// An error raised after the LAST command must still fail: nothing follows it to attribute it to,
/// so without an end-of-scenario drain the run would report success over a broken app.
///
/// A top-level sibling, NOT nested inside another scenario: nesting would keep an idle outer app
/// alive and blur which scenario owns the failure and its teardown.
Future<void> _trailingErrorStillFails() async {
  const name = 'app_errors_trailing';
  final base = Platform.environment['SIM_TEST_ARTIFACTS_DIR'];
  final dir = Directory(
    base == null || base.isEmpty ? 'build/sim-failures/$name' : base,
  );
  final before = dir.existsSync()
      ? {for (final e in dir.listSync()) e.path}
      : <String>{};

  final escaped = await _failureOf(() async {
    await SimHarness.runScenario(name, (h) async {
      // An ASYNC error timed to arrive after the last command's own drain — a synchronous one is
      // caught by the very request that provoked it, which is better attribution but never
      // exercises the end-of-scenario path.
      await h.provokeAsyncError(after: const Duration(milliseconds: 200));
      await Future<void>.delayed(const Duration(milliseconds: 600));
      // Deliberately no driver command afterwards: nothing left to attribute it to.
    }, deviceCount: 0);
  });
  if (!escaped.contains('end of scenario') ||
      !escaped.contains('deliberate async failure')) {
    throw StateError(
      'an error after the last command must fail at scenario end — got: $escaped',
    );
  }

  // Remove what this deliberate failure wrote, so a passing run leaves no error file to mislead
  // whoever reads the artifacts next.
  if (dir.existsSync()) {
    for (final f in dir.listSync().whereType<File>()) {
      if (!before.contains(f.path) && f.path.endsWith('error.txt')) {
        f.deleteSync();
      }
    }
  }

  stdout.writeln(
    'APP_ERRORS_TRAILING_OK: an error raised after the last command still failed the scenario',
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
