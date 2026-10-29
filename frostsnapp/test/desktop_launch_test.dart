import 'package:flutter_test/flutter_test.dart';

import '../test_driver/sim_harness.dart' show desktopLaunchSupported;

void main() {
  test('only a native macOS or Linux desktop sim app is launched', () {
    const targets = ['macos', 'linux', 'windows'];
    const hosts = ['macos', 'linux', 'windows'];
    final launched = [
      for (final target in targets)
        for (final host in hosts)
          if (desktopLaunchSupported(target: target, hostOs: host))
            '$target on $host',
    ];
    expect(launched, ['macos on macos', 'linux on linux']);
  });
}
