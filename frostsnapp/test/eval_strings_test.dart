import 'package:flutter_test/flutter_test.dart';

import '../test_driver/eval_strings.dart';

// fsim-eval-full-strings: the paging logic behind `fsim eval`'s result/error printing. The VM service
// truncates `valueAsString` to a preview; a wrong reassembly here silently corrupts every long eval output.
void main() {
  group('assembleFullString', () {
    test(
      'not truncated returns the preview verbatim, never fetching',
      () async {
        var fetches = 0;
        final out = await assembleFullString('hello', false, 5, (_, _) async {
          fetches++;
          return '';
        });
        expect(out, 'hello');
        expect(fetches, 0);
      },
    );

    test('null preview passes through when not truncated', () async {
      expect(
        await assembleFullString(null, false, null, (_, _) async => ''),
        isNull,
      );
    });

    test('truncated pages in order and reassembles exactly', () async {
      const source = 'abcdefghijklmnopqrst';
      final calls = <(int, int)>[];
      final out = await assembleFullString('abcdefg', true, source.length, (
        offset,
        count,
      ) async {
        calls.add((offset, count));
        return source.substring(offset, offset + count);
      }, chunkSize: 7);
      expect(out, source);
      // The preview is NOT trusted as a prefix — paging restarts from 0.
      expect(calls, [(0, 7), (7, 7), (14, 6)]);
    });

    test('a short chunk throws instead of assembling a corrupt value', () {
      expect(
        assembleFullString('ab', true, 100, (_, _) async => 'x', chunkSize: 10),
        throwsStateError,
      );
    });

    test('a null chunk throws instead of looping forever', () {
      expect(
        assembleFullString('ab', true, 100, (_, _) async => null),
        throwsStateError,
      );
    });

    test('truncated with unknown length throws', () {
      expect(
        assembleFullString('ab', true, null, (_, _) async => 'x'),
        throwsStateError,
      );
    });
  });
}
