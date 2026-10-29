// fsim-app-pixel-tap: tooltip targeting stays a WIDGET finder (`find.byTooltip` needs one exact
// string) — this resolver turns any Pattern into that string with diagnostics. Pure Dart: it runs in
// the HARNESS process (no dart:ui).

/// Resolve [tooltip] to EXACTLY one of [available] (the tooltips currently on stage). Every input —
/// exact `String` included — takes this path, so an unknown tooltip always gets the diagnostic
/// listing (never a raw finder timeout) and a duplicated exact tooltip errors with its matches.
/// String matches by equality; any other [Pattern] by containment (`allMatches`).
String resolveTooltip(Pattern tooltip, List<String> available) {
  final matches = available
      .where(
        (t) =>
            tooltip is String ? t == tooltip : tooltip.allMatches(t).isNotEmpty,
      )
      .toList();
  if (matches.isEmpty) {
    throw StateError(
      'no on-stage tooltip matches "$tooltip" — available tooltips: '
      '${available.isEmpty ? '(none)' : available.map((t) => '"$t"').join(', ')}',
    );
  }
  if (matches.length > 1) {
    throw StateError(
      '"$tooltip" is ambiguous — it matches: ${matches.map((t) => '"$t"').join(', ')}',
    );
  }
  return matches.single;
}
