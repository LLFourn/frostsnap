import 'dart:io';

import 'regtest.dart';

// Owner harness for test/regtest_owner_reap_test.dart. Spawns a real isolated regtest session and idles,
// holding the death-pipe (its stdin write end). The test reads the pids, then SIGKILLs OWNER_PID — THIS
// dart VM, the write-end holder — to mimic a hung-test reap that skips Dart teardown, and asserts the
// detached backend self-reaps. Prints `OWNER_PID=`/`BACKEND_PID=` (one per line) then blocks forever.
Future<void> main() async {
  final dir = Directory(
    '/tmp/frs_ort_$pid',
  ); // short path: the control socket has a ~104B cap
  if (dir.existsSync()) dir.deleteSync(recursive: true);
  final session = await startRegtestSession(dir);
  stdout.writeln('OWNER_PID=$pid');
  stdout.writeln('BACKEND_PID=${session.pid}');
  await stdout.flush();
  await Future<void>.delayed(const Duration(hours: 1));
}
