// fsim-android-ime-text: android text entry rides `adb shell input text`, so a payload transits TWO
// parsers — the device shell (adb joins args, the device `sh` tokenizes) and `input text`'s decoder
// (the literal sequence `%s` becomes a space). Validation + encoding are a PURE preflight computed
// before the harness touches the app: a rejected payload must leave the field and focus untouched.

/// Why [text] cannot be typed through the on-screen keyboard, or null if it can. Typeable = printable
/// ASCII (0x20–0x7E) with no literal `%s` (the device decoder would turn it into a space — unpreservable).
/// Empty text is valid and means clear-only.
String? imeTextPreflightError(String text) {
  for (var i = 0; i < text.length; i++) {
    final c = text.codeUnitAt(i);
    if (c < 0x20 || c > 0x7e) {
      return 'cannot type ${_describeChar(text[i])} at index $i through the android on-screen '
          'keyboard — only printable ASCII is supported (use the driver mock on a host session, or '
          'session.adb key events)';
    }
  }
  final pct = text.indexOf('%s');
  if (pct >= 0) {
    return "cannot type a literal '%s' (index $pct) through the android on-screen keyboard — the "
        "device's `input text` decodes it to a space";
  }
  return null;
}

/// The exact `adb shell input text <arg>` argument for a preflight-clean, non-empty [text]: space →
/// `%s` (the `input text` space convention — the argument must be one shell word), then single-quoted
/// for the device shell so quotes/`$`/backticks/backslashes ride through untouched (embedded `'`
/// becomes `'\''`).
String encodeImeText(String text) {
  final spaced = text.replaceAll(' ', '%s');
  return "'${spaced.replaceAll("'", "'\\''")}'";
}

String _describeChar(String ch) {
  final code = ch.codeUnitAt(0);
  final hex = 'U+${code.toRadixString(16).padLeft(4, '0').toUpperCase()}';
  if (code < 0x20) return 'control character $hex';
  // A surrogate half (emoji etc.) is not printable on its own — name it by code unit only.
  if (code >= 0xd800 && code <= 0xdfff) return 'non-ASCII character $hex';
  return "'$ch' ($hex)";
}
