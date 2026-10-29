import 'package:flutter_test/flutter_test.dart';

import '../test_driver/driver_phase.dart';
import '../test_driver/host_load.dart';

// Several sessions share one machine; when they swamp it, a starved emulator reads like a hung app.
void main() {
  test('reads the 1-minute load from macOS and Linux', () {
    expect(parseLoad1('{ 8.56 9.73 11.43 }\n'), 8.56);
    expect(parseLoad1('26.10 20.02 15.3 3/1234 5678\n'), 26.10);
    expect(parseLoad1('no numbers here'), isNull);
  });

  test('a host with cores to spare has nothing to say', () {
    expect(hostLoadFinding(load1: 8.5, cores: 18), isNull);
    expect(hostLoadFinding(load1: 18, cores: 18), isNull);
  });

  test('more runnable work than cores is named, with the numbers', () {
    final finding = hostLoadFinding(load1: 42.3, cores: 18)!;
    expect(finding, contains('overloaded'));
    expect(finding, contains('42.3'));
    expect(finding, contains('18 cores'));
  });

  test('the finding leads a refusal', () {
    final finding = hostLoadFinding(load1: 42.3, cores: 18)!;
    final refusal = SessionQuarantined(
      strayVerb: 'tapTooltip("More")',
      strayPhase: DriverPhase.action,
      refusedVerb: 'exists("Receive")',
      waited: const Duration(seconds: 3),
    ).withEnvironment(finding);
    expect('$refusal', startsWith(finding));
  });
}
