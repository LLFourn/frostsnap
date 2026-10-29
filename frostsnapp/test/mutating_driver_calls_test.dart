import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// A mutating driver command sent with a `timeout:` gets an extension-side `Future.timeout`, which
// answers "Timeout while executing" while the handler runs on. The harness then has nothing that
// marks the end of that work, and a quarantine cannot lift itself. Every such call must leave the
// deadline to the harness's own guard.
void main() {
  const mutating = [
    'driver.tap(',
    'driver.enterText(',
    'driver.scrollIntoView(',
    'driver.requestData(',
    // The frame-sync toggles: app-global state, and a stray restore quarantines like a mutation.
    'driver.sendCommand(',
  ];

  /// The argument list of the call starting at [open], the index of its `(`.
  String argsOf(String src, int open) {
    var depth = 0;
    for (var i = open; i < src.length; i++) {
      if (src[i] == '(') depth++;
      if (src[i] == ')' && --depth == 0) return src.substring(open, i + 1);
    }
    throw StateError('unbalanced call at $open');
  }

  test(
    'no mutating driver call in the harness passes an extension timeout',
    () {
      final src = File('test_driver/sim_harness.dart').readAsStringSync();
      final offenders = <String>[];
      var seen = 0;
      for (final call in mutating) {
        for (
          var at = src.indexOf(call);
          at >= 0;
          at = src.indexOf(call, at + 1)
        ) {
          seen++;
          final args = argsOf(src, at + call.length - 1);
          if (args.contains('timeout:')) {
            final line = '\n'.allMatches(src.substring(0, at)).length + 1;
            offenders.add('sim_harness.dart:$line $call…');
          }
        }
      }
      expect(
        seen,
        greaterThan(0),
        reason: 'the scan found no call sites at all',
      );
      expect(offenders, isEmpty);
    },
  );
}
