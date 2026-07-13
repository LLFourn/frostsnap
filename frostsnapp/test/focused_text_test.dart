import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test_driver/focused_text.dart';

// fsim-android-ime-text: the android REPLACE clear backspaces exactly focusedTextLength() times. The
// semantics snapshot TRIMS values, so a count derived from it under-counts edge whitespace and leaves
// content behind — this query must return the raw length, and "no focused field" must be detectable
// (null) so the app handler can fail loudly instead of clearing/typing into the void.
void main() {
  testWidgets('returns the exact UNTRIMMED length (edge whitespace counts)', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    // 10 leading + 10 trailing spaces — more than any fixed slack; a trimmed
    // count would miss all 20.
    const value = '          x          ';
    await tester.pumpWidget(
      MaterialApp(
        home: Material(
          child: TextField(
            autofocus: true,
            controller: TextEditingController(text: value),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(focusedTextLength(tester.binding.rootElement!), value.length);
    semantics.dispose();
  });

  testWidgets('null when no text field is focused', (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(
        home: Material(
          child: TextField(controller: TextEditingController(text: 'idle')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(focusedTextLength(tester.binding.rootElement!), isNull);
    semantics.dispose();
  });

  testWidgets('null when there is no text field at all', (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(const MaterialApp(home: Text('no fields')));
    await tester.pumpAndSettle();
    expect(focusedTextLength(tester.binding.rootElement!), isNull);
    semantics.dispose();
  });
}
