import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../test_driver/regtest.dart' show androidSdkRoot;
import '../test_driver/sim_harness.dart' show simTmpRoot;

// Regression guard for the emulator pool's self-heal (sim-pool-self-heal). A slot used to be claimed
// by a bare lockfile and judged busy by EXISTENCE alone, so a crashed/killed run left a dead lock that
// wedged the pool ("emulator pool exhausted") until a manual `pool reset`. A claim now records the
// claiming runner's PID + that PID's start-time; a slot is reclaimed when its claimant is gone OR its
// pid was recycled by a different process (start-time mismatch), while a genuinely live claimant is
// never touched.
//
// This drives the real `./simctl pool` CLI against hand-seeded lockfiles — no emulator boots — so it
// stays fast and host-runnable. It needs the Android SDK (the pool is android-specific), so it skips
// on a host-only checkout.
bool _hasAndroidSdk() {
  try {
    androidSdkRoot();
    return true;
  } catch (_) {
    return false;
  }
}

String _pidStarted(int p) =>
    (Process.runSync('ps', ['-p', '$p', '-o', 'lstart=']).stdout as String)
        .trim();

void main() {
  final repoRoot = Directory.current.parent.path;
  final poolDir = Directory('${simTmpRoot().path}/pool');

  Future<Map<String, dynamic>> pool(List<String> args) async {
    final r = await Process.run('./simctl', [
      'pool',
      ...args,
    ], workingDirectory: repoRoot);
    expect(
      r.exitCode,
      0,
      reason: 'simctl pool ${args.join(' ')} failed:\n${r.stdout}\n${r.stderr}',
    );
    // status/reconcile each print a single JSON object on stdout (reconcile's per-slot log is stderr).
    return jsonDecode((r.stdout as String).trim().split('\n').last)
        as Map<String, dynamic>;
  }

  void seedClaim(
    int slot, {
    required int claimantPid,
    required String started,
  }) {
    poolDir.createSync(recursive: true);
    File('${poolDir.path}/slot-$slot.lock').writeAsStringSync(
      jsonEncode({
        'pid': claimantPid,
        'started': started,
        'serial': 'emulator-${5582 + slot * 2}',
        'ts': 0,
      }),
    );
  }

  setUp(() => pool(['reset']));
  tearDown(() => pool(['reset']));

  test(
    'reconcile reclaims dead and recycled-pid claims but never a live one',
    () async {
      // slot 0: claimant process is gone.
      seedClaim(0, claimantPid: 999999, started: 'Thu Jan  1 00:00:00 2000');
      // slot 1: claimed by THIS live test process, with its real start-time → genuinely live.
      seedClaim(1, claimantPid: pid, started: _pidStarted(pid));
      // slot 2: pid is alive but the recorded start-time does not match — i.e. the original claimant
      // died and an unrelated process inherited its pid. Must read as stale (the reuse guard).
      seedClaim(2, claimantPid: pid, started: 'Thu Jan  1 00:00:00 2000');

      final before = await pool(['status']);
      final stale = {
        for (final c in before['claimed'] as List) c['slot']: c['stale'],
      };
      expect(stale[0], isTrue, reason: 'a gone claimant reads stale');
      expect(
        stale[1],
        isFalse,
        reason: 'a live claimant (matching start) reads live',
      );
      expect(
        stale[2],
        isTrue,
        reason: 'a recycled pid (start mismatch) reads stale',
      );

      final reconciled = await pool(['reconcile']);
      expect(
        reconciled['reconciled'],
        [0, 2],
        reason:
            'reconcile reclaims the gone and recycled-pid slots, not the live one',
      );

      final after = await pool(['status']);
      final survivors = [for (final c in after['claimed'] as List) c['slot']];
      expect(survivors, [1], reason: 'only the genuinely live claim survives');
    },
    skip: _hasAndroidSdk()
        ? false
        : 'requires the Android SDK (pool is android-specific)',
  );
}
