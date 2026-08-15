/// The vocabulary of a driver command's failure, and the one rule that decides whether a failure
/// leaves the session untrustworthy. Kept dependency-free so the decision is unit-testable without
/// a driver or an app (`test/driver_phase_test.dart` covers the whole matrix).
library;

/// Which phase of a driver command a failure happened in. One command is several round trips —
/// disable frame sync, resolve a target, dispatch, restore frame sync — and reporting them as one
/// is why several tests can share a timeout message without sharing a cause.
enum DriverPhase {
  /// Turning frame sync off, before the action.
  frameSyncOff,

  /// Resolving the target WITHOUT hit-testability, before dispatch: separates "no such label"
  /// from "the label is there but never becomes actionable" (e.g. behind a modal barrier).
  preflight,

  /// The action itself: the driver command's own round trip.
  action,

  /// Turning frame sync back on, after the action.
  frameSyncOn,
}

/// What a driver call DOES to the app. Required at every call site on purpose: an optional
/// "mutating" flag defaulting to false silently classified six mutating paths as observations,
/// and nothing failed until a timeout let one of them act after the harness moved on.
enum DriverEffect {
  /// Changes the app: a tap, a text entry, an injected gesture. If it times out it may still land.
  mutates,

  /// Reads the app: a wait, a text read, a semantics probe. A timeout changes nothing.
  observes,

  /// A SIM-ONLY operation the caller deliberately leaves in flight, knowing it will not answer —
  /// today only `stall:`, whose whole purpose is to stop the app responding. Its timeout is the
  /// intended outcome, not evidence of anything, so it marks nothing.
  ///
  /// Separate from [observes] rather than folded into it: a stall is not a read, and calling it
  /// one would make "an observation's timeout changes nothing" false. Anything that genuinely
  /// alters app state — `animate:`, which starts a global ticker — is [mutates], not this.
  detached,
}

/// Whether the app was asked what is at the target, and what came back.
enum ProbeOutcome {
  /// No target-specific probe applies — a tooltip, coordinate or text-entry action has no label to
  /// ask about. Distinct from [unanswered]: nothing was attempted, so nothing was learned.
  notApplicable,

  /// The app was asked and did not answer, which says the app itself is stalled.
  unanswered,

  /// A probe APPLIED but was never sent: the caller's deadline was already spent. Distinct from
  /// [unanswered], which is an observation about the app — this one says only that we ran out of
  /// time to make it, and claiming the app went silent would be inventing evidence.
  notAttempted,

  /// The app answered; see the report.
  answered,
}

/// Whether a phase failure leaves work that could still land, making later results untrustworthy.
///
/// Two independent reasons, and BOTH matter:
///  * a MUTATING action that timed out — flutter_driver's extension wraps its handler in
///    `Future.timeout` without cancelling it, so the tap can still be delivered afterwards;
///  * any phase our own guard abandoned — nothing cancels there either, whatever it was.
///
/// A preflight that timed out is neither: the action was never dispatched. An observing command
/// that the driver timed out is neither — not because it finished (its handler is uncancelled too,
/// so it may well still be running) but because what it goes on to do cannot change the app. That
/// exclusion is what keeps `tapUntil`'s constant negative polls from quarantining every session.
bool quarantinesSession({
  required DriverEffect effect,
  required DriverPhase phase,
  required bool abandoned,
}) =>
    (effect == DriverEffect.mutates && phase == DriverPhase.action) ||
    abandoned;

/// Whether a failed APP-CHANNEL request (`requestData`) leaves work that could still land.
///
/// The driver-command rule above has two residues; this path has one. A data request never calls
/// `waitForElement` and — since it stopped being wrapped in `runUnsynchronized` — leaves no pending
/// frame-sync toggle either, so the only thing outstanding is the app-side handler.
///
/// BOTH conditions are needed, and [abandoned] is the one that is easy to drop. A single `catch`
/// here covers two very different failures: the app ANSWERED with an error, or we gave up waiting.
/// Only the second leaves a handler running. Tests deliberately provoke the first — connecting a
/// removed device, `stale-handle-probe:` — and catch it; quarantining those poisons a session that
/// is working exactly as intended, and because `exists`/`appears` swallow every exception, the
/// refusal surfaces as a silently WRONG false rather than as an error.
/// [DriverEffect.detached] never marks: not answering is what the caller asked for.
bool appChannelQuarantines({
  required DriverEffect effect,
  required bool abandoned,
}) => effect == DriverEffect.mutates && abandoned;

/// Raised when a session refuses an operation because something outstanding could land inside it.
///
/// A DISTINCT type on purpose. The boolean predicates (`exists`, `appears`) answer "is it there?"
/// by catching, and a refusal caught as `false` reports a present label as absent — the test then
/// takes a wrong branch and fails far from the cause. Predicates must let this one through.
class SessionQuarantined implements Exception {
  /// What is still running.
  final String strayVerb;
  final DriverPhase strayPhase;

  /// What was refused because of it.
  final String refusedVerb;

  SessionQuarantined({
    required this.strayVerb,
    required this.strayPhase,
    required this.refusedVerb,
  });

  @override
  String toString() =>
      '$refusedVerb refused: $strayVerb timed out in ${strayPhase.name} and is STILL RUNNING '
      '(a timeout cancels nothing, on either channel). Whatever it goes on to do would land in '
      'the middle of this one.';
}

/// A timeout that knows which [DriverPhase] it happened in, what the app said about the target,
/// and how it compared to its budget.
class DriverPhaseTimeout implements Exception {
  final DriverPhase phase;
  final DriverEffect effect;
  final String verb;
  final Duration budget;
  final Duration elapsed;

  /// True when OUR guard gave up while the command was still outstanding.
  ///
  /// It does NOT mean "the only dangerous case": flutter_driver's extension does not cancel its
  /// handler either, so a MUTATING command the driver timed out can still act afterwards. What
  /// this distinguishes is the OBSERVING commands — a predicate poll may still be running, but
  /// nothing it can do changes the app. See [quarantinesSession].
  final bool abandoned;

  /// Whether the app was asked what sits at the target (see [ProbeOutcome]).
  final ProbeOutcome probe;

  /// What the app said, when [probe] is [ProbeOutcome.answered].
  final String? hitTest;

  /// The label the action was aimed at, so the failure can ask the app about it. Null for actions
  /// that have no label — a tooltip, a coordinate, a text entry.
  final Pattern? target;

  DriverPhaseTimeout({
    required this.phase,
    required this.effect,
    required this.verb,
    required this.budget,
    required this.elapsed,
    required this.abandoned,
    this.probe = ProbeOutcome.notApplicable,
    this.target,
    this.hitTest,
  });

  DriverPhaseTimeout withProbe(ProbeOutcome outcome, [String? report]) =>
      DriverPhaseTimeout(
        phase: phase,
        effect: effect,
        verb: verb,
        budget: budget,
        elapsed: elapsed,
        abandoned: abandoned,
        probe: outcome,
        target: target,
        hitTest: report,
      );

  /// What the phase means, in the terms a reader of a failure needs.
  String get diagnosis => switch (phase) {
    // Split deliberately: a frameSyncOn failure happens AFTER the action, so "the action never
    // ran" would be false about a command that may well have done its work.
    DriverPhase.frameSyncOff =>
      'the app did not answer when frame sync was disabled — it is wedged or gone, and the action '
          'never ran',
    DriverPhase.frameSyncOn =>
      'the app did not answer when frame sync was restored, AFTER the action — the action may have '
          'run, and frame sync is left disabled for whatever comes next',
    DriverPhase.preflight =>
      'no widget matched, so the action was never dispatched (a label miss, not a stuck app)',
    DriverPhase.action => switch (probe) {
      ProbeOutcome.answered =>
        'the action did not complete; the app reports $hitTest',
      ProbeOutcome.unanswered =>
        'the action did not complete, and the app did not answer when asked what is at the '
            'target — app/isolate contention rather than anything about the target',
      // NOT the same as unanswered: nothing was asked, so this says nothing about the app.
      ProbeOutcome.notApplicable =>
        'the action did not complete; it has no label to ask the app about, so what blocked it '
            'is unknown from here',
      ProbeOutcome.notAttempted =>
        'the action did not complete; the deadline was spent before the app could be asked what is '
            'at the target, so this says nothing about the app',
    },
  };

  @override
  String toString() =>
      '$verb timed out in ${phase.name} after ${elapsed.inMilliseconds}ms '
      '(budget ${budget.inMilliseconds}ms): $diagnosis';
}
