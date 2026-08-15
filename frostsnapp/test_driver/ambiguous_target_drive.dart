import 'dart:io';

import 'sim_harness.dart';

// A tap must name exactly ONE control (fsim-deterministic-targets M1).
//
// The observed failure was two identical hit-testable "Close" buttons — two sheets stacked while
// one closed — reported by FlutterDriver as `Found 2 widgets … ambiguously found multiple matching
// widgets`, a fact about its own widget search rather than about the choice the test failed to
// make. Every case here forces that shape deterministically with the duplicate-target fixture,
// because waiting for a mid-transition overlap to recur is exactly the flakiness being removed.
//
// Run: `./fsim test ambiguous_target`.

const _label = 'CloseProbe';

Future<void> main() async {
  await SimHarness.runScenario('ambiguous_target', (h) async {
    // 1. TWO IDENTICAL labels — the observed shape. A resolver built on the deduplicating
    //    `semantics().labels()` would see one candidate here and report no problem at all.
    await h.showDuplicateTargets(_label, 2);
    final ambiguous = await _failureOf(() => h.tap(_label));
    if (!ambiguous.contains('could not pick a target') ||
        !ambiguous.contains('"$_label" x2') ||
        !ambiguous.contains('2 hit-testable targets')) {
      throw StateError(
        'an ambiguous tap must report the candidates and their counts in the test\'s own '
        'vocabulary — got: $ambiguous',
      );
    }
    if (ambiguous.contains('ambiguously found multiple matching widgets')) {
      throw StateError(
        'the driver-internal widget-count message leaked through: $ambiguous',
      );
    }
    // ACTION-FAITHFUL: the probe's count must be the count the driver's own finder produced. They
    // are separate observations, so the diagnostic says so when they differ — and here, against a
    // real app, they must not. This pins the invariant for every ambiguity the suite ever hits,
    // rather than for one staged geometry.
    if (ambiguous.contains('NOTE:')) {
      throw StateError(
        'the reachability probe disagreed with the driver that raised the failure — the counts are '
        'not being taken the way the action takes them: $ambiguous',
      );
    }

    // 2. EXISTENTIAL observations keep their contract: a wait exists to watch a screen in flux, so
    //    two matches is a normal state to pass through, NOT a failure. This is the half that a
    //    uniqueness rule applied indiscriminately would break.
    if (!await h.exists(_label)) {
      throw StateError('exists() must still answer true for a doubled label');
    }
    await h.waitFor(_label);

    // 3. The SETTLE path, pinning the decision policy. Two candidates now, one after a delay:
    //    tapWhenUnique must retry the ACTION (never tap on the strength of a count read) and fire
    //    exactly once. A loop that acted on every attempt would leave taps > 1.
    await h.showDuplicateTargets(
      _label,
      2,
      settleAfter: const Duration(seconds: 3),
    );
    await h.tapWhenUnique(_label, timeout: const Duration(seconds: 15));
    final taps = await h.duplicateTargetTaps();
    if (taps != 1) {
      throw StateError(
        'tapWhenUnique must act EXACTLY once — the app recorded $taps activations',
      );
    }

    // 4. A target that never settles fails with the counts observed, so "it stayed ambiguous" is
    //    distinguishable from "it never appeared".
    await h.showDuplicateTargets(_label, 2);
    final never = await _failureOf(
      () => h.tapWhenUnique(_label, timeout: const Duration(seconds: 2)),
    );
    if (!never.contains('never settled') || !never.contains('x2')) {
      throw StateError(
        'a target that stays ambiguous should say so and show the counts — got: $never',
      );
    }

    await h.clearDuplicateTargets();
    stdout.writeln(
      'AMBIGUOUS_TARGET_OK: two identical labels report candidates and counts, observations still '
      'answer, tapWhenUnique settled and acted exactly once, and the reported count matched the '
      'driver\'s own',
    );
  }, deviceCount: 0);

  // tapWithin is a singular action like any other, so it must obey the SAME phase contract: a
  // missing ancestor or descendant is a PREFLIGHT miss — nothing was dispatched, so the session
  // must not be quarantined — and an ambiguous descendant must be explained with the counts inside
  // the SCOPE, not the global ones the action never searched.
  await SimHarness.runScenario('ambiguous_target_scoped', (h) async {
    await h.showDuplicateTargets(_label, 2);

    // 1. Missing ANCESTOR. Nothing was tapped, so nothing may be left outstanding.
    final noAncestor = await _failureOf(
      () => h.tapWithin('NoSuchKey_ScopeProbe', _label),
    );
    if (noAncestor.contains('STILL RUNNING')) {
      throw StateError(
        'a scoped tap that never dispatched must not quarantine the session — got: $noAncestor',
      );
    }
    // It must NAME the absent ancestor. The label exists elsewhere on screen, so a global probe
    // would find it and report a generic action failure about a target that was never in scope.
    if (!noAncestor.contains('no widget keyed "NoSuchKey_ScopeProbe"')) {
      throw StateError(
        'a missing ancestor must be named, not explained by the whole screen — got: $noAncestor',
      );
    }
    // Proof the session is still usable: a later observation must answer, not be refused.
    if (await h.hitTestableCount(_label) != 2) {
      throw StateError(
        'the session should still be usable after a preflight miss',
      );
    }

    // 2. Missing DESCENDANT inside a real ancestor — also a preflight miss, not a stuck action.
    final noDescendant = await _failureOf(
      () => h.tapWithin('sim-duplicate-targets', 'NoSuchLabel_ScopeProbe'),
    );
    if (noDescendant.contains('STILL RUNNING')) {
      throw StateError(
        'a missing descendant must not quarantine the session — got: $noDescendant',
      );
    }
    // ...and it must say WITHIN WHAT, listing that scope rather than the whole stage.
    if (!noDescendant.contains('within "sim-duplicate-targets"') ||
        !noDescendant.contains('labels in that scope') ||
        !noDescendant.contains('"$_label"')) {
      throw StateError(
        'a missing descendant must be reported against its scope, listing what that scope holds — '
        'got: $noDescendant',
      );
    }

    // 3. Ambiguous WITHIN the scope: the diagnostic must name the scope and count inside it.
    final ambiguous = await _failureOf(
      () => h.tapWithin('sim-duplicate-targets', _label),
    );
    if (!ambiguous.contains('could not pick a target') ||
        !ambiguous.contains('within "sim-duplicate-targets"') ||
        !ambiguous.contains('"$_label" x2')) {
      throw StateError(
        'a scoped ambiguity must be explained with the scope and its own counts — got: $ambiguous',
      );
    }

    // 4. A scope whose ROOT carries the label — the `matchRoot: true` case. Every assertion above
    //    matches a DESCENDANT, so a probe that skipped the scope root would agree with the action
    //    by accident and this contract would be untested.
    if (await h.hitTestableCount('RootScopeProbe', within: 'sim-scope-root') !=
        1) {
      throw StateError(
        'the scope ROOT carries the label, so the scoped count must see exactly it — the probe is '
        'skipping the root the action can hit',
      );
    }
    final before = await h.duplicateTargetTaps();
    await h.tapWithin('sim-scope-root', 'RootScopeProbe');
    if (await h.duplicateTargetTaps() != before + 1) {
      throw StateError(
        'tapWithin must hit a scope root that carries the label',
      );
    }

    // 5. When the scoped probe cannot be ANSWERED, the failure must not claim the scope is absent:
    //    that is a statement about the tree from a probe that never saw it.
    await h.blockNextDataRequest(const Duration(seconds: 25));
    final probeFailed = await _failureOf(
      () => h.tapWithin('sim-duplicate-targets', 'NoSuchLabel_ScopeProbe'),
    );
    if (probeFailed.contains('no widget keyed')) {
      throw StateError(
        'an unanswered probe must not be reported as a missing scope — got: $probeFailed',
      );
    }
    if (!probeFailed.contains('could not be asked')) {
      throw StateError(
        'an unanswered scoped probe should say the app could not be asked — got: $probeFailed',
      );
    }

    await h.clearDuplicateTargets();
    stdout.writeln(
      'AMBIGUOUS_TARGET_SCOPED_OK: a missing ancestor is named, a missing descendant is reported '
      'against its scope with that scope listed, neither quarantines, a scoped ambiguity reports '
      'the scope and its own counts, a scope ROOT carrying the label is both counted and tapped, '
      'and an unanswered probe is not reported as a missing scope',
    );
  }, deviceCount: 0);

  // Its OWN session, because this one QUARANTINES itself by design: a timed-out attempt may still
  // land, so nothing after it can be trusted — including the fixture cleanup, which is a mutation
  // and is refused. That boundary is per AppSession, which this both relies on and demonstrates.
  await SimHarness.runScenario('ambiguous_target_timeout', (h) async {
    // A dispatched ACTION that times out is TERMINAL. Stalling the app before the call instead
    // times out the first frame-sync phase and never dispatches anything — the tap count stays 0
    // and an "at most once" assertion passes however broken the retry policy is. So the tap handler
    // itself blocks: frame-sync-off and the finder complete, the tap lands exactly once, and only
    // then does the app stop answering.
    await h.showDuplicateTargets(_label, 1);
    await h.blockDuplicateTargetTap(const Duration(seconds: 12));

    final started = DateTime.now();
    final timedOut = await _failureOf(
      () => h.tapWhenUnique(_label, timeout: const Duration(seconds: 4)),
    );
    final took = DateTime.now().difference(started);

    if (timedOut.contains('never settled')) {
      throw StateError(
        'a timed-out ACTION must not be reported as repeated ambiguity — got: $timedOut',
      );
    }
    // WHICH phase matters. The frame-sync restore runs afterwards against the same blocked app and
    // fails too; a `finally` that throws would replace this error with a frameSyncOn timeout and
    // lose the cause. Asserting only "not never-settled" let that masking pass.
    if (!timedOut.contains('timed out in action')) {
      throw StateError(
        'the ACTION timeout must survive the failing frame-sync restore that follows it — '
        'got: $timedOut',
      );
    }
    // The deadline covers the WHOLE call: the action phase, the frame-sync restore in the finally,
    // and every post-failure probe. Each of those used to carry an independent budget that ran on
    // after the caller had stopped waiting.
    if (took > const Duration(seconds: 8)) {
      throw StateError(
        'tapWhenUnique took ${took.inSeconds}s against a 4s deadline — some phase or post-failure '
        'probe is still running on its own budget: $timedOut',
      );
    }

    // The action WAS dispatched (so this is a real action timeout, not an earlier phase failing)
    // and exactly once. Read over the diagnostic path: the timeout quarantined the session.
    await Future<void>.delayed(const Duration(seconds: 13));
    final dispatched = await h.duplicateTargetTaps();
    if (dispatched != 1) {
      throw StateError(
        'expected the action to be dispatched exactly once, the app recorded $dispatched '
        '(0 means it never reached the tap — the case would prove nothing)',
      );
    }

    stdout.writeln(
      'AMBIGUOUS_TARGET_TIMEOUT_OK: a dispatched action timed out, was never retried, reported the '
      'ACTION phase, and the whole call honoured the deadline (${took.inSeconds}s for 4s)',
    );
  }, deviceCount: 0);

  // A diagnostic that starts with time still on the clock and then does not answer. Checking that
  // time remains and THEN letting the probe spend its own budget is not a bound — the ambiguity
  // here is raised in milliseconds, so the candidate probe begins with almost the whole deadline
  // left and would run to its own timeout against an app that will not reply.
  await SimHarness.runScenario('ambiguous_target_slow_probe', (h) async {
    await h.showDuplicateTargets(_label, 2);
    // Armed AFTER the fixture is confirmed reachable, so it lands on the diagnostic probe.
    await h.blockNextDataRequest(const Duration(seconds: 25));

    final started = DateTime.now();
    final failed = await _failureOf(
      () => h.tapWhenUnique(_label, timeout: const Duration(seconds: 4)),
    );
    final took = DateTime.now().difference(started);
    if (took > const Duration(seconds: 9)) {
      throw StateError(
        'the candidate probe kept its own budget: ${took.inSeconds}s against a 4s deadline — '
        '$failed',
      );
    }
    if (!failed.contains('never settled')) {
      throw StateError('expected the operation to give up, got: $failed');
    }

    stdout.writeln(
      'AMBIGUOUS_TARGET_SLOW_PROBE_OK: an unanswered diagnostic did not outlive the deadline '
      '(${took.inSeconds}s for 4s)',
    );
  }, deviceCount: 0);
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
