// fsim-android-ime-text: the android REPLACE clear backspaces the focused field's value away, so it
// needs the value's EXACT length. The semantics snapshot trims values for display — edge whitespace
// would be invisible there and survive the clear — so this reads the raw semantics value instead.

import 'package:flutter/widgets.dart';

/// Exact UNTRIMMED semantics-value length of the focused text field under [root], or null if no
/// focused text field exists (the caller decides how loudly to fail).
int? focusedTextLength(Element root) {
  int? len;
  void visit(Element element) {
    if (len != null) return;
    if (element is RenderObjectElement) {
      final semantics = element.renderObject.debugSemantics;
      if (semantics != null) {
        final data = semantics.getSemanticsData();
        final flags = data.flagsCollection.toStrings();
        if (flags.contains('isTextField') && flags.contains('isFocused')) {
          len = data.value.length;
          return;
        }
      }
    }
    element.visitChildren(visit);
  }

  root.visitChildren(visit);
  return len;
}
