import 'package:flutter_test/flutter_test.dart';

import '../test_driver/ime_text.dart';

// fsim-android-ime-text: the pure preflight behind android IME typing. The payload transits the device
// shell AND `input text`'s `%s` decoder — a wrong contract here silently types the WRONG text. The
// harness only mutates UI (tap/clear) after a null preflight error, so rejection here IS
// rejection-before-side-effects.

/// What the device does to the argument: the shell strips our single quotes, then `input text`
/// rewrites `%s` to a space.
String deviceDecode(String encoded) {
  expect(encoded, startsWith("'"));
  expect(encoded, endsWith("'"));
  final shellWord = encoded
      .substring(1, encoded.length - 1)
      .replaceAll("'\\''", "'");
  return shellWord.replaceAll('%s', ' ');
}

void main() {
  group('imeTextPreflightError', () {
    test('printable ASCII passes', () {
      expect(imeTextPreflightError('frost wallet 42!'), isNull);
    });

    test('empty text is valid (clear-only)', () {
      expect(imeTextPreflightError(''), isNull);
    });

    test('non-ASCII is rejected naming char and index', () {
      final err = imeTextPreflightError('café')!;
      expect(err, contains('é'));
      expect(err, contains('index 3'));
    });

    test('an emoji (surrogate pair) is rejected without printing garbage', () {
      final err = imeTextPreflightError('a\u{1F600}b')!;
      expect(err, contains('index 1'));
      expect(err, contains('U+D83D'));
    });

    test('a control character is rejected', () {
      final err = imeTextPreflightError('a\tb')!;
      expect(err, contains('control character U+0009'));
      expect(err, contains('index 1'));
    });

    test("a literal '%s' is rejected (device decodes it to a space)", () {
      final err = imeTextPreflightError('50%soff')!;
      expect(err, contains("'%s'"));
      expect(err, contains('index 2'));
    });

    test("a lone '%' is fine", () {
      expect(imeTextPreflightError('100%'), isNull);
      expect(imeTextPreflightError('a% b'), isNull);
    });
  });

  group('encodeImeText', () {
    // decode(encode(t)) == t is the whole contract: what the device types is exactly what was asked.
    const roundTripVectors = [
      'hello world',
      'a  b', // multiple spaces
      ' leading and trailing ',
      '100%',
      'a% b', // '%' adjacent to an encoded space
      'a %b',
      "it's a 'quoted' name",
      'she said "hi"',
      r'dollar $ backtick ` backslash \ semi ; pipe | star * tilde ~',
      'bcrt1qw508d6qejxtdg4y5r3zarvary0c5xw7kygt080', // bech32 address
    ];

    for (final t in roundTripVectors) {
      test('round-trips ${t.length > 24 ? '${t.substring(0, 24)}…' : t}', () {
        expect(imeTextPreflightError(t), isNull);
        expect(deviceDecode(encodeImeText(t)), t);
      });
    }

    test('the result is one single-quoted shell word', () {
      final encoded = encodeImeText('two words');
      expect(encoded, "'two%swords'");
    });

    test("embedded single quotes use the '\\'' dance", () {
      expect(encodeImeText("a'b"), r"'a'\''b'");
    });
  });
}
