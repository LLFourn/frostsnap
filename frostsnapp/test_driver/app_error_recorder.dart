import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'app_errors.dart' show simErrorWidgetLabel;

/// Every Flutter error the app raises, kept where a test can ask about it.
///
/// Without this the harness only ever saw errors as `[app:err]` stderr text: capped at 400
/// lines, never asserted on, and read by a human only when some OTHER failure produced an
/// artifact. A red screen, a `setState() after dispose()` or an assertion in `build` left the
/// app running and the scenario green.
///
/// TWO recorders and one renderer, deliberately:
///  * [FlutterError.onError] is the authoritative record for framework errors;
///  * [PlatformDispatcher.instance.onError] records async errors that escape their zone;
///  * `ErrorWidget.builder` records NOTHING — a build failure has already been reported through
///    `FlutterError.onError` with the same details, so recording there too would make one defect
///    into two events and leave it ambiguous which one an expectation consumed.
class AppErrorRecorder {
  AppErrorRecorder._();
  static final AppErrorRecorder instance = AppErrorRecorder._();

  final _pending = <Map<String, Object?>>[];
  var _nextId = 1;
  DateTime? _startedAt;

  /// Identity of THIS app process. Ids restart at 1 in every generation, so a harness cursor
  /// carried across a restart would prune the new generation's first errors and see nothing. The
  /// generation travels with every read so that reset is detected rather than assumed.
  String? _generation;

  /// Install the hooks, each CHAINING to the handler it replaces so the console a human reads is
  /// unchanged. Call before `runApp`.
  var _installed = false;

  void install() {
    // Idempotent: each install chains to the handler it replaced, so installing twice in one
    // isolate would make every error record once per layer — quietly breaking the one-error-one-
    // event invariant that expectations depend on.
    if (_installed) return;
    _installed = true;
    _startedAt ??= DateTime.now();
    _generation ??=
        '${DateTime.now().microsecondsSinceEpoch}-${identityHashCode(this)}';

    final priorOnError = FlutterError.onError;
    FlutterError.onError = (details) {
      _record(
        kind: 'flutter-error',
        summary: details.summary.toString(),
        library: details.library ?? '',
        context: details.context?.toString() ?? '',
        stack: details.stack?.toString() ?? '',
      );
      priorOnError?.call(details);
    };

    final priorPlatformOnError = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = (error, stack) {
      _record(
        kind: 'uncaught-async',
        summary: '$error',
        library: 'zone',
        context: '',
        stack: '$stack',
      );
      // FALSE when there was no prior handler: `true` claims the error is handled and suppresses
      // the platform's own console reporting, which would break the promise that what a human sees
      // is unchanged. Recording it here is not handling it.
      return priorPlatformOnError?.call(error, stack) ?? false;
    };

    // Renders only. The failure it is rendering was already recorded above.
    final priorBuilder = ErrorWidget.builder;
    ErrorWidget.builder = (details) => Semantics(
      container: true,
      label: simErrorWidgetLabel,
      child: priorBuilder(details),
    );
  }

  void _record({
    required String kind,
    required String summary,
    required String library,
    required String context,
    required String stack,
  }) {
    _pending.add({
      'id': _nextId++,
      'kind': kind,
      'summary': summary,
      'library': library,
      'context': context,
      'stack': stack,
      'sinceStartMs': DateTime.now()
          .difference(_startedAt ?? DateTime.now())
          .inMilliseconds,
    });
  }

  /// Events after [ackUpTo], WITHOUT consuming them.
  ///
  /// Take-and-clear loses errors, which is the opposite of the point. The clearing happens app-side
  /// the moment the request runs — so a request the harness ABANDONED at its deadline can still
  /// arrive, wipe the queue, and deliver its answer to nobody. The next boundary then sees an empty
  /// list and the error is gone for good.
  ///
  /// So nothing is dropped until the harness says it HAS the events: [ackUpTo] is an id it already
  /// received, pruning is limited to that, and everything after it is returned again on the next
  /// read. An abandoned read costs a round trip, never an error.
  /// Events after [ackUpTo], WITHOUT consuming them — and pruning ONLY when [ackGeneration] names
  /// this app.
  ///
  /// The generation guard is not decoration. Ids restart at 1 in every process, so a cursor of 3
  /// carried across a restart would delete the new generation's ids 1..3 here, BEFORE the harness
  /// could see the token had changed and reset. That silently loses startup errors — the ones
  /// raised before any test does anything, which nothing else would ever surface.
  String readSince(String ackGeneration, int ackUpTo) {
    if (ackGeneration == _generation) {
      _pending.removeWhere((e) => (e['id'] as int) <= ackUpTo);
    }
    return jsonEncode({'generation': _generation ?? '', 'events': _pending});
  }

  /// Test-only reset, for unit coverage of the recorder itself.
  @visibleForTesting
  void resetForTest() {
    _pending.clear();
    _nextId = 1;
    _startedAt = null;
    _generation = 'test-generation';
  }

  @visibleForTesting
  void newGenerationForTest(String generation) {
    _pending.clear();
    _nextId = 1;
    _generation = generation;
  }

  @visibleForTesting
  void recordForTest({required String kind, required String summary}) =>
      _record(
        kind: kind,
        summary: summary,
        library: '',
        context: '',
        stack: '',
      );
}
