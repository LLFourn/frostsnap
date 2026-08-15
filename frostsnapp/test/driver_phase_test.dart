import 'package:flutter_test/flutter_test.dart';

import '../test_driver/driver_phase.dart';

// When does a failed driver command leave the session untrustworthy, and what does the failure
// claim to know? Both were got wrong by inspection before: quarantine was keyed off "has a finder"
// (so six mutating paths escaped it), and a missing probe answer was reported as app contention
// even when nothing had been asked. Neither is inspectable from an e2e that only exercises one
// path, so the whole matrix is pinned here.
void main() {
  group('quarantine matrix', () {
    test('a mutating ACTION quarantines however the timeout was reported', () {
      // The driver reporting it does not mean it finished: flutter_driver's extension does not
      // cancel its handler, so the tap can still land after the harness moved on.
      for (final abandoned in [true, false]) {
        expect(
          quarantinesSession(
            effect: DriverEffect.mutates,
            phase: DriverPhase.action,
            abandoned: abandoned,
          ),
          isTrue,
          reason: 'mutating action, abandoned=$abandoned',
        );
      }
    });

    test('an OBSERVING command the driver timed out does not', () {
      // tapUntil polls constantly and most polls find nothing. If those quarantined, every test
      // would fail on its second command.
      for (final phase in DriverPhase.values) {
        expect(
          quarantinesSession(
            effect: DriverEffect.observes,
            phase: phase,
            abandoned: false,
          ),
          isFalse,
          reason: 'observing, $phase, driver-reported',
        );
      }
    });

    test('ANY abandoned phase quarantines, including the frame-sync toggles', () {
      // Our own guard giving up means that command is still running, whatever it was — and the
      // frame-sync toggles run outside the action, which is how they were missed before.
      for (final effect in DriverEffect.values) {
        for (final phase in DriverPhase.values) {
          expect(
            quarantinesSession(effect: effect, phase: phase, abandoned: true),
            isTrue,
            reason: '$effect, $phase, abandoned',
          );
        }
      }
    });

    test('a mutating PREFLIGHT the driver timed out does not', () {
      // The finder never resolved, so the action was never dispatched: nothing can land.
      expect(
        quarantinesSession(
          effect: DriverEffect.mutates,
          phase: DriverPhase.preflight,
          abandoned: false,
        ),
        isFalse,
      );
    });
  });

  group('app-channel quarantine', () {
    test('only a mutating request WE gave up on quarantines', () {
      // `add-device` completing after its caller stopped waiting changes what every later command
      // sees; an unanswered `metrics` read leaves nothing behind.
      expect(
        appChannelQuarantines(effect: DriverEffect.mutates, abandoned: true),
        isTrue,
      );
      expect(
        appChannelQuarantines(effect: DriverEffect.observes, abandoned: true),
        isFalse,
      );
    });

    test('a mutating endpoint that ANSWERED with an error does not', () {
      // The case that broke device_lifecycle: one `catch` covers "the app answered with an error"
      // and "we gave up waiting", and only the second leaves a handler running. Tests provoke the
      // first on purpose (connecting a removed device, stale-handle-probe) and catch it. Because
      // `exists`/`appears` swallow every exception, quarantining here does not raise — it makes a
      // present label report as absent, and the test then takes a wrong branch far from the cause.
      expect(
        appChannelQuarantines(effect: DriverEffect.mutates, abandoned: false),
        isFalse,
      );
    });

    test('a detached request marks nothing — not answering is the point', () {
      // `stall:` exists to stop the app responding. Its timeout is the intended outcome, so it is
      // neither a mutation to quarantine nor an observation whose timeout "changes nothing".
      for (final abandoned in [true, false]) {
        expect(
          appChannelQuarantines(
            effect: DriverEffect.detached,
            abandoned: abandoned,
          ),
          isFalse,
          reason: 'detached, abandoned=$abandoned',
        );
      }
    });

    test('the two channels do NOT share one rule', () {
      // A driver command abandoned in any phase quarantines whatever its effect, because its
      // `runUnsynchronized` `finally` still owes a frame-sync restore. Data requests stopped being
      // wrapped in it, so effect must also be satisfied. If these ever re-converge, reconcile them
      // deliberately rather than letting one absorb the other.
      expect(
        quarantinesSession(
          effect: DriverEffect.observes,
          phase: DriverPhase.action,
          abandoned: true,
        ),
        isTrue,
      );
      expect(
        appChannelQuarantines(effect: DriverEffect.observes, abandoned: true),
        isFalse,
      );
    });
  });

  group('a refusal is not an answer', () {
    test(
      'SessionQuarantined names the stray, its phase, and what it refused',
      () {
        final refusal = SessionQuarantined(
          strayVerb: 'requestData("add-device")',
          strayPhase: DriverPhase.action,
          refusedVerb: 'exists("Add device")',
        ).toString();
        expect(refusal, contains('requestData("add-device")'));
        expect(refusal, contains('exists("Add device")'));
        expect(refusal, contains('STILL RUNNING'));
        // It must not read as a fact about the target — that is the failure mode it exists to stop.
        expect(refusal, contains('refused'));
      },
    );
  });

  group('what a failure claims to know', () {
    DriverPhaseTimeout timeout({
      DriverPhase phase = DriverPhase.action,
      ProbeOutcome probe = ProbeOutcome.notApplicable,
      String? hitTest,
      Pattern? target,
    }) => DriverPhaseTimeout(
      phase: phase,
      effect: DriverEffect.mutates,
      verb: 'tap("X")',
      budget: const Duration(seconds: 20),
      elapsed: const Duration(seconds: 20),
      abandoned: false,
      probe: probe,
      target: target,
      hitTest: hitTest,
    );

    test('an answered probe reports what the app said', () {
      final d = timeout(
        probe: ProbeOutcome.answered,
        hitTest: '"X" is present but NOT hit-testable — a tap lands on Barrier',
      ).diagnosis;
      expect(d, contains('NOT hit-testable'));
      expect(d, contains('Barrier'));
    });

    test('an unanswered probe blames the app, not the target', () {
      expect(
        timeout(probe: ProbeOutcome.unanswered).diagnosis,
        contains('contention'),
      );
    });

    test('a targetless mutation says nothing was asked — NOT contention', () {
      // A tooltip / coordinate / text-entry action has no label to ask about. Reporting that as
      // "the app did not answer" would blame the app for a probe that never happened.
      final d = timeout(probe: ProbeOutcome.notApplicable).diagnosis;
      expect(d, contains('no label to ask the app about'));
      expect(d, isNot(contains('contention')));
      expect(d, isNot(contains('did not answer')));
    });

    test('an exhausted deadline does NOT claim the app was asked', () {
      // The probe APPLIED but was never sent. Reporting `unanswered` here would assert an
      // observation about the app that was never made — the same invented evidence the
      // notApplicable/unanswered split exists to prevent.
      final d = timeout(probe: ProbeOutcome.notAttempted).diagnosis;
      expect(d, contains('deadline was spent'));
      expect(d, contains('says nothing about the app'));
      expect(d, isNot(contains('did not answer')));
      expect(d, isNot(contains('contention')));
    });

    test('a probe that was SENT and stayed silent still blames the app', () {
      // The other side of the split: an attempted probe that times out IS evidence.
      final d = timeout(probe: ProbeOutcome.unanswered).diagnosis;
      expect(d, contains('did not answer'));
      expect(d, contains('contention'));
      expect(d, isNot(contains('deadline was spent')));
    });

    test('a preflight failure reads as a label miss, not a stuck app', () {
      final d = timeout(phase: DriverPhase.preflight).diagnosis;
      expect(d, contains('never dispatched'));
      expect(d, contains('label miss'));
    });

    test('frame-sync OFF failing means the action never ran', () {
      final d = timeout(phase: DriverPhase.frameSyncOff).diagnosis;
      expect(d, contains('never ran'));
    });

    test('frame-sync ON failing must NOT claim the action never ran', () {
      // The restore happens AFTER the action, so a standalone failure there says nothing about
      // whether the action worked — and leaves frame sync disabled for whatever runs next.
      final d = timeout(phase: DriverPhase.frameSyncOn).diagnosis;
      expect(d, isNot(contains('never ran')));
      expect(d, contains('may have run'));
      expect(d, contains('left disabled'));
    });

    test('the message names the phase and both durations', () {
      expect(
        timeout().toString(),
        allOf(contains('action'), contains('20000ms'), contains('budget')),
      );
    });
  });
}
