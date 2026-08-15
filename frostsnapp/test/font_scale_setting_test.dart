import 'package:flutter_test/flutter_test.dart';

import '../test_driver/font_scale_setting.dart';

// A font-scale read that is not a scale must not pass for a restored one.
void main() {
  test('an unset setting is the default scale', () {
    expect(fontScaleSetting('null'), 1.0);
  });

  test('a written setting is its value', () {
    expect(fontScaleSetting('1.3'), 1.3);
  });

  test('anything else is an error, not 1.0', () {
    expect(() => fontScaleSetting(''), throwsStateError);
    expect(() => fontScaleSetting('error: device offline'), throwsStateError);
  });
}
