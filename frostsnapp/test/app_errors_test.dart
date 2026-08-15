import 'package:flutter_test/flutter_test.dart';

import '../test_driver/app_errors.dart';

AppError err({
  int id = 1,
  String kind = 'flutter-error',
  String summary = 'Bad state: something broke',
  String context = '',
}) => AppError(
  id: id,
  kind: kind,
  summary: summary,
  library: 'widgets library',
  context: context,
  stack: '#0 somewhere',
);

void main() {
  group('the cursor', () {
    test('a new GENERATION resets it — ids restart at 1 in every app process', () {
      // The session outlives a restart. Without this, a cursor advanced to 3 before the restart
      // would prune the new generation's ids 1..3 and report nothing: silent loss exactly where a
      // reset makes it hardest to notice.
      final cursor = AppErrorCursor();
      cursor.accept('gen-a', [err(id: 1), err(id: 2), err(id: 3)]);
      expect(cursor.sinceId, 3);

      final afterRestart = cursor.accept('gen-b', [
        err(id: 1, summary: 'new gen'),
      ]);
      expect(afterRestart.map((e) => e.summary), ['new gen']);
      expect(cursor.sinceId, 1);
    });

    test('the same generation continues, dropping what was already received', () {
      final cursor = AppErrorCursor();
      cursor.accept('gen-a', [err(id: 1), err(id: 2)]);
      final next = cursor.accept('gen-a', [
        err(id: 2),
        err(id: 3, summary: 'fresh'),
      ]);
      expect(
        next.map((e) => e.summary),
        ['fresh'],
        reason:
            'id 2 was already reported; reporting it twice is a false fact about the app',
      );
    });

    test('two overlapping reads with the same cursor cannot double-report', () {
      // An abandoned read leaves the cursor unmoved, so a retry asks for the same range. Filtering
      // on RECEIPT is what stops the same event surfacing twice.
      final cursor = AppErrorCursor();
      final first = cursor.accept('gen-a', [err(id: 1), err(id: 2)]);
      final overlapping = cursor.accept('gen-a', [err(id: 1), err(id: 2)]);
      expect(first.length, 2);
      expect(overlapping, isEmpty);
    });

    test(
      'it starts at zero and reports no generation before the first read',
      () {
        final cursor = AppErrorCursor();
        expect(cursor.sinceId, 0);
        expect(cursor.generation, isNull);
      },
    );
  });

  group('parsing the app payload', () {
    test('reads every field, and ids survive', () {
      final parsed = AppError.fromJson([
        {
          'id': 7,
          'kind': 'uncaught-async',
          'summary': 'Bad state: async',
          'library': 'zone',
          'context': 'while doing a thing',
          'stack': '#0 frame',
          'sinceStartMs': 1234,
        },
      ]);
      expect(parsed.single.id, 7);
      expect(parsed.single.kind, 'uncaught-async');
      expect(parsed.single.summary, 'Bad state: async');
      expect(parsed.single.context, 'while doing a thing');
      expect(parsed.single.stack, '#0 frame');
      expect(
        parsed.single.sinceStartMs,
        1234,
        reason: 'when the error happened is part of the record, not decoration',
      );
    });

    test(
      'missing optional fields do not throw — a partial event still reports',
      () {
        // The recorder always sends them, but an event that arrives thin must still be reportable:
        // dropping it on a parse error would lose exactly the error we exist to surface.
        final parsed = AppError.fromJson([
          {'id': 1, 'kind': 'flutter-error', 'summary': 'boom'},
        ]);
        expect(parsed.single.summary, 'boom');
        expect(parsed.single.stack, isEmpty);
      },
    );

    test('the id is what the cursor advances on, so it must round-trip', () {
      final parsed = AppError.fromJson([
        {'id': 3, 'kind': 'k', 'summary': 'a'},
        {'id': 9, 'kind': 'k', 'summary': 'b'},
      ]);
      expect(parsed.map((e) => e.id), [3, 9]);
    });
  });

  group('what an expectation claims', () {
    test('a String matches by substring, against summary AND context', () {
      // "thrown while building X" lives in the context and is often the only part that identifies
      // which error this is, so matching only the summary would make many allowances unwritable.
      expect(
        AppErrorExpectation(
          'overflowed',
        ).consume(err(summary: 'A RenderFlex overflowed by 3px')),
        isTrue,
      );
      expect(
        AppErrorExpectation(
          'while building',
        ).consume(err(context: 'thrown while building MyWidget')),
        isTrue,
      );
    });

    test('a RegExp matches', () {
      expect(
        AppErrorExpectation(
          RegExp(r'overflowed by \d+px'),
        ).consume(err(summary: 'A RenderFlex overflowed by 3px')),
        isTrue,
      );
    });

    test('so does a Pattern that is NEITHER String nor RegExp', () {
      // `Pattern` is an interface anything can implement. Casting every non-String to RegExp — the
      // first version of this — throws on any other implementation, which is a crash in the code
      // that reports crashes.
      expect(
        AppErrorExpectation(
          _EndsWith('by 3px'),
        ).consume(err(summary: 'A RenderFlex overflowed by 3px')),
        isTrue,
      );
      expect(AppErrorExpectation(_EndsWith('zzz')).consume(err()), isFalse);
      // An empty context must not leave a trailing space: it silently breaks any pattern anchored
      // at the end, which is how this was found.
      expect(err(summary: 'exact').matchable, 'exact');
    });

    test(
      'a non-match is NOT claimed, and leaves the expectation unmatched',
      () {
        final x = AppErrorExpectation('something else');
        expect(x.consume(err()), isFalse);
        expect(
          x.matched,
          isFalse,
          reason: 'an unrelated error must not satisfy an allowance',
        );
      },
    );

    test('matched latches, so a scope that fired once is not stale', () {
      final x = AppErrorExpectation('broke');
      expect(x.consume(err()), isTrue);
      expect(x.consume(err(summary: 'unrelated')), isFalse);
      expect(x.matched, isTrue);
    });
  });

  group('what the failure says', () {
    test('it names the command and carries every error with its stack', () {
      final raised = AppErrorRaised(
        verb: 'tap("Send")',
        errors: [
          err(summary: 'first'),
          err(id: 2, summary: 'second'),
        ],
      ).toString();
      expect(raised, contains('tap("Send")'));
      expect(raised, contains('2 Flutter error'));
      expect(raised, contains('first'));
      expect(raised, contains('second'));
      expect(raised, contains('#0 somewhere'));
    });

    test('it refuses the "console noise" reading explicitly', () {
      final raised = AppErrorRaised(verb: 'tap("Send")', errors: [err()]);
      expect('$raised', contains('not console noise'));
    });
  });
}

/// A Pattern that is neither a String nor a RegExp, to prove the matcher does not assume either.
class _EndsWith implements Pattern {
  final String suffix;
  const _EndsWith(this.suffix);

  @override
  Iterable<Match> allMatches(String string, [int start = 0]) =>
      string.endsWith(suffix) ? [_TrivialMatch(string, this)] : const [];

  @override
  Match? matchAsPrefix(String string, [int start = 0]) => null;
}

class _TrivialMatch implements Match {
  @override
  final String input;
  @override
  final Pattern pattern;
  const _TrivialMatch(this.input, this.pattern);
  @override
  int get start => 0;
  @override
  int get end => 0;
  @override
  int get groupCount => 0;
  @override
  String? group(int group) => null;
  @override
  String? operator [](int group) => null;
  @override
  List<String?> groups(List<int> groupIndices) => const [];
}
