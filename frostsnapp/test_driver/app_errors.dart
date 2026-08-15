/// What a Flutter error looks like to the HARNESS, and the rule for allowing one.
///
/// Dependency-free on purpose: the harness runs on the plain Dart VM, where `dart:ui` does not
/// exist, so anything it imports must not reach into Flutter. The recorder that installs the hooks
/// lives in `app_error_recorder.dart` and runs inside the app.
library;

/// The semantic label carried by every rendered error widget, so a wrecked subtree is targetable
/// from a test instead of merely red. Defined here — the one side both can import.
const simErrorWidgetLabel = 'SIM_FLUTTER_ERROR_WIDGET';

/// What the harness has already received, per app GENERATION.
///
/// Ids restart at 1 in every new app process, and the session outlives a restart — so a cursor
/// carried across one would prune the new generation's first errors and report nothing. That is
/// silent loss precisely where a reset makes it hardest to notice, so the generation is part of the
/// protocol rather than something the harness infers.
///
/// It also filters on RECEIPT: two reads issued with the same cursor (one abandoned, one not) would
/// otherwise surface the same event twice, and a duplicate error is a false fact about the app.
class AppErrorCursor {
  String? _generation;
  var _acked = 0;

  /// The id to ask from. Zero whenever the generation is unknown or has changed.
  int get sinceId => _acked;

  /// The generation this cursor is tracking, or null before the first read.
  String? get generation => _generation;

  /// Take what a read returned, dropping anything already seen and advancing past the rest.
  List<AppError> accept(String generation, List<AppError> events) {
    if (generation != _generation) {
      _generation = generation;
      _acked = 0;
    }
    final fresh = events.where((e) => e.id > _acked).toList();
    for (final e in fresh) {
      if (e.id > _acked) _acked = e.id;
    }
    return fresh;
  }
}

/// One Flutter error the app raised, as the harness sees it.
class AppError {
  final int id;
  final String kind;
  final String summary;
  final String library;
  final String context;
  final String stack;

  /// Milliseconds since the app generation started — which of several errors came first, and how
  /// far into the run, without trusting the harness's own clock across a restart.
  final int sinceStartMs;

  const AppError({
    required this.id,
    required this.kind,
    required this.summary,
    required this.library,
    required this.context,
    required this.stack,
    this.sinceStartMs = 0,
  });

  static List<AppError> fromJson(List<dynamic> json) => [
    for (final e in json.cast<Map<String, dynamic>>())
      AppError(
        id: e['id'] as int,
        kind: e['kind'] as String,
        summary: e['summary'] as String? ?? '',
        library: e['library'] as String? ?? '',
        context: e['context'] as String? ?? '',
        stack: e['stack'] as String? ?? '',
        sinceStartMs: e['sinceStartMs'] as int? ?? 0,
      ),
  ];

  /// What an expectation matches against: the summary plus the context Flutter attaches, since
  /// "thrown while building X" is often the only part that identifies which error this is.
  String get matchable =>
      [summary, context].where((s) => s.isNotEmpty).join(' ');

  @override
  String toString() =>
      '[$kind] $summary${context.isEmpty ? '' : ' ($context)'}'
      '${library.isEmpty ? '' : ' — $library'}';
}

/// An allowance for Flutter errors matching [pattern], active for one scope.
///
/// ACTIVE consumer, not a mute button: it claims only matching events, anything else still fails,
/// and a scope that closes having matched nothing is itself a failure.
class AppErrorExpectation {
  final Pattern pattern;
  var matched = false;

  AppErrorExpectation(this.pattern);

  bool consume(AppError error) {
    // General Pattern, not a RegExp cast: `Pattern` is an interface anything can implement, and
    // `allMatches` is the method every implementation provides.
    final hit = pattern is String
        ? error.matchable.contains(pattern as String)
        : pattern.allMatches(error.matchable).isNotEmpty;
    if (hit) matched = true;
    return hit;
  }
}

/// The app raised Flutter errors that no expectation claimed.
class AppErrorRaised implements Exception {
  /// The command this followed — the app was fine before it and not after.
  final String verb;
  final List<AppError> errors;

  AppErrorRaised({required this.verb, required this.errors});

  @override
  String toString() {
    final listed = errors.map((e) => '  • $e').join('\n');
    final stacks = errors
        .where((e) => e.stack.isNotEmpty)
        .map((e) => e.stack)
        .join('\n---\n');
    return 'the app raised ${errors.length} Flutter error(s) during $verb — a red error in the app '
        'is a failure of the test that provoked it, not console noise:\n$listed'
        '${stacks.isEmpty ? '' : '\n\n$stacks'}';
  }
}
