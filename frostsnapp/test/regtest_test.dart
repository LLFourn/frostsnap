import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../test_driver/regtest.dart';

// Regression guard for the regtest faucet's singleton/no-clobber invariant (the Dart half).
// codex flagged that an earlier `_up` unconditionally unlinked the control socket before
// spawning, so a second concurrent `up` could delete a socket the first backend had just
// bound — orphaning its node. The fix: `up` must NEVER unlink the socket; the Rust binary's
// bind_control_socket owns stale cleanup and refuses a live one. (The Rust singleton guard is
// covered by sim_regtest's bind_control_socket_is_a_singleton test; this covers the Dart side.)
void main() {
  test('regtest up is idempotent and never unlinks a live backend socket', () async {
    final socketPath = regtestControlSocket;

    // Stand in for a live backend: a unix server that answers {"ok":true,"pid":...} to any line
    // (so regtestLive()'s ping, which now requires the owner pid, succeeds). No real
    // bitcoind/electrs — this is a pure Dart check.
    try {
      File(socketPath).deleteSync();
    } catch (_) {}
    final dummy = await ServerSocket.bind(
      InternetAddress(socketPath, type: InternetAddressType.unix),
      0,
    );
    dummy.listen((conn) {
      conn
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            if (line.trim().isNotEmpty) {
              conn.write('{"ok":true,"pid":1,"url":"tcp://127.0.0.1:1"}\n');
            }
          });
    });
    await File(regtestUrlFile).writeAsString('tcp://127.0.0.1:1');

    try {
      // The backend reads as live...
      expect(await regtestLive(), isTrue);

      // ...so `up` must early-return WITHOUT touching the socket (no deleteSync, no spawn).
      await runRegtest(['up']);

      expect(
        File(socketPath).existsSync(),
        isTrue,
        reason: 'up must not unlink a live backend control socket',
      );
      expect(
        await regtestLive(),
        isTrue,
        reason: 'the live backend must still be reachable after `up`',
      );
    } finally {
      await dummy.close();
      try {
        File(socketPath).deleteSync();
      } catch (_) {}
      try {
        File(regtestUrlFile).deleteSync();
      } catch (_) {}
    }
  });

  // Two invariants of the SHARED PERSISTENT backend. (1) Ownership election: `ensureRegtestBackend`
  // returns owned:true only for the caller whose spawned child actually won the Rust
  // bind_control_socket singleton — the live backend reports its PID (`ping`) and a caller owns it
  // only if that PID is the child it spawned, so concurrent auto-starts elect exactly ONE owner
  // (used only to report started-vs-attached, NOT a teardown duty). (2) Persistence: the node is
  // reaped ONLY by an explicit `./simctl regtest down` / `clean` — a session teardown NEVER stops
  // it (SimHarness no longer reaps the backend). Spawns REAL bitcoind+electrs (the race is decided
  // by the OS socket bind + real PIDs, which a fake socket can't reproduce), so it is heavy.
  test(
    'concurrent ensureRegtestBackend elects exactly one owner; the shared node persists until an explicit reap',
    () async {
      final repoRoot = Directory.current.parent.path;
      final build = await Process.run('cargo', [
        'build',
        '-q',
        '-p',
        'sim_regtest',
      ], workingDirectory: repoRoot);
      expect(
        build.exitCode,
        0,
        reason: 'sim_regtest build failed:\n${build.stderr}',
      );

      // Clean slate: no live backend (else `ensure` would just attach and never race) and no stale
      // socket/url left by a previous run.
      await stopRegtestBackend();
      for (var i = 0; i < 40 && await regtestLive(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      expect(
        await regtestLive(),
        isFalse,
        reason:
            'a prior backend is still live; cannot test the auto-start race',
      );
      try {
        File(regtestControlSocket).deleteSync();
      } catch (_) {}
      try {
        File(regtestUrlFile).deleteSync();
      } catch (_) {}

      try {
        final results = await Future.wait([
          ensureRegtestBackend(),
          ensureRegtestBackend(),
        ]);

        expect(
          results.where((r) => r.owned).length,
          1,
          reason:
              'the singleton elects ONE backend; only the caller whose spawned child won may own it',
        );
        expect(
          results[0].url,
          results[1].url,
          reason: 'both callers resolve to the same shared node',
        );
        expect(await regtestLive(), isTrue);

        // (2) Persistence: a session teardown NEVER reaps the node — SimHarness._cleanup no longer
        // stops the backend, so `owned` carries no teardown duty and the node stays up regardless
        // of which caller spawned it.
        expect(
          await regtestLive(),
          isTrue,
          reason: 'the shared node stays up — sessions never reap it',
        );

        // It is reaped ONLY by an explicit `./simctl regtest down` / `clean`, modelled here by a
        // direct stopRegtestBackend().
        await stopRegtestBackend();
        for (var i = 0; i < 40 && await regtestLive(); i++) {
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
        expect(
          await regtestLive(),
          isFalse,
          reason: 'an explicit regtest down / clean reaps the persistent node',
        );
      } finally {
        await stopRegtestBackend();
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
