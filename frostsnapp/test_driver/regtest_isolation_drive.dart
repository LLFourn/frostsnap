import 'dart:io';

import 'regtest.dart';
import 'sim_harness.dart' show simTmpRoot;

// parallel-android-tests Task 2 acceptance: two PER-SESSION regtest backends are fully isolated —
// each its own bitcoind+electrs (dynamic ports, private datadir), so a `mine` on one does NOT touch
// the other's chain, and both reap cleanly (PID gone, control socket removed) on stop. This is the
// property that lets regtest tests run in PARALLEL without a shared `mine` racing another test's
// pending receive. Host-only; needs no emulator. Run: `./simctl test regtest_isolation`.
Future<void> main() async {
  // Per-PROCESS base (`rti-$pid`) so two concurrent copies of THIS test (`--jobs 2 regtest_isolation
  // regtest_isolation`) don't race over the same sockets/dirs. Short, to keep the control sockets
  // under the unix-socket path limit (~104 on macOS).
  final base = Directory('${simTmpRoot().path}/rti-$pid');
  if (base.existsSync()) base.deleteSync(recursive: true);

  // Nullable so the finally reaps WHICHEVER sessions were created — if B fails to start, A is
  // already running and must still be stopped (no orphaned process group).
  RegtestSession? a;
  RegtestSession? b;
  try {
    a = await startRegtestSession(Directory('${base.path}/a'));
    b = await startRegtestSession(Directory('${base.path}/b'));
    if (a.url == b.url) {
      throw 'sessions share a URL (${a.url}) — not isolated';
    }
    stdout.writeln('two backends up: A=${a.url}  B=${b.url}');

    final fa = await a.faucet();
    final fb = await b.faucet();
    try {
      final aBefore = await fa.blockHeight();
      final bBefore = await fb.blockHeight();
      await fa.mine(5); // mine on A ONLY
      final aAfter = await fa.blockHeight();
      final bAfter = await fb.blockHeight();
      if (aAfter != aBefore + 5) {
        throw 'A height $aBefore -> $aAfter, expected +5';
      }
      if (bAfter != bBefore) {
        throw 'B height moved ($bBefore -> $bAfter) when only A mined — chains NOT isolated';
      }
      stdout.writeln(
        'isolation OK: A $aBefore->$aAfter (+5), B $bBefore->$bAfter (unchanged)',
      );
    } finally {
      await fa.close();
      await fb.close();
    }

    // Stop on the success path, then assert a clean reap (no orphaned bitcoind/electrs, sockets
    // removed). stop() is idempotent, so the finally below is a harmless backstop.
    await a.stop();
    await b.stop();
    for (final s in [a, b]) {
      final alive =
          (await Process.run('kill', ['-0', '${s.pid}'])).exitCode == 0;
      if (alive) throw 'backend pid ${s.pid} still alive after stop (leak)';
      if (File(s.controlSocket).existsSync()) {
        throw 'control socket ${s.controlSocket} not removed after stop';
      }
    }
    stdout.writeln(
      'REGTEST_ISOLATION_OK: two isolated chains, both reaped cleanly',
    );
  } finally {
    await a?.stop();
    await b?.stop();
  }
}
