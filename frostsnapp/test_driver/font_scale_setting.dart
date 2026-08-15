/// What `settings get system font_scale` prints when the setting has never been written.
const unsetFontScale = 'null';

/// `settings get system font_scale` as a scale. `null` is the setting never written, which is the
/// default 1.0; anything else that is not a number is an error, not a scale — reading it as 1.0
/// would let a broken read pass for a restored one.
double fontScaleSetting(String setting) {
  if (setting == unsetFontScale) return 1.0;
  final scale = double.tryParse(setting);
  if (scale == null) {
    throw StateError(
      '`settings get system font_scale` printed "$setting", not a scale',
    );
  }
  return scale;
}
