import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// Integration regression for regtest-session-lifetime: a per-session regtest backend is bound to its
// owning process by an OS death-pipe — startRegtestSession spawns it `detachedWithStdio` with
// `--reap-on-owner-exit` and holds the stdin write end. SIGKILL the owner (the path a hung-test reap or
// a crash takes — it skips the Dart `finally` that calls stop()) and the DETACHED backend plus its
// bitcoind/electrs must self-reap: no `ppid=1` orphan. This spawns a real backend (bitcoind+electrs), so
// it is slow and host-only; the owner probe builds it.
bool _alive(int pid) => Process.runSync('kill', ['-0', '$pid']).exitCode == 0;

void main() {
  test(
    'a per-session regtest backend self-reaps when its owner is SIGKILLed',
    () async {
      final owner = await Process.start('dart', [
        'run',
        'test_driver/regtest_owner_probe.dart',
      ]);
      // The owner is SIGKILLed mid-test by design; reap the launcher too if anything goes wrong.
      addTearDown(() => owner.kill(ProcessSignal.sigkill));

      final pids = <String, int>{};
      final ready = Completer<void>();
      owner.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            final m = RegExp(r'^(OWNER|BACKEND)_PID=(\d+)$').firstMatch(line);
            if (m != null) pids[m.group(1)!] = int.parse(m.group(2)!);
            if (pids.length == 2 && !ready.isCompleted) ready.complete();
          });
      // First run builds sim_regtest and boots bitcoind/electrs, which is slow.
      await ready.future.timeout(const Duration(seconds: 180));
      addTearDown(() {
        // If the test FAILS (backend not reaped, i.e. a regression), don't leave the orphan behind:
        // reap its process group (the backend pid is its group leader). A no-op on the normal pass.
        Process.runSync('kill', ['-9', '--', '-${pids['BACKEND']}']);
        final d = Directory('/tmp/frs_ort_${pids['OWNER']}');
        if (d.existsSync()) d.deleteSync(recursive: true);
      });

      final backend = pids['BACKEND']!;
      expect(
        _alive(backend),
        isTrue,
        reason: 'backend should be up before the kill',
      );

      // SIGKILL the owner (the dart VM holding the death-pipe write end). No Dart teardown runs — this
      // is exactly the abnormal death a finally-based reap cannot survive.
      Process.killPid(pids['OWNER']!, ProcessSignal.sigkill);

      // The kernel closes the write end → the backend reads EOF → it stops and drops, reaping its
      // bitcoind/electrs. Generous window; the reap is normally sub-second (20ms serve poll).
      var reaped = false;
      final deadline = DateTime.now().add(const Duration(seconds: 15));
      while (DateTime.now().isBefore(deadline)) {
        if (!_alive(backend)) {
          reaped = true;
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(
        reaped,
        isTrue,
        reason:
            'backend $backend must self-reap after its owner is SIGKILLed (no orphan)',
      );
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
