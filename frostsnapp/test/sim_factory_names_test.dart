import 'package:flutter_test/flutter_test.dart';
import 'package:frostsnap/src/rust/api/sim.dart' as app;

import '../test_driver/sim_harness.dart' as harness;

void main() {
  test("the driver names the app's factories exactly", () {
    expect(
      harness.SimFactory.values.map((f) => f.name),
      app.SimFactory.values.map((f) => f.name),
    );
  });
}
