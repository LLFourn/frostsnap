import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../test_driver/emulator_lifecycle.dart';
import '../test_driver/slot_lease.dart';

// fsim-test-worktree-isolation: the LOCK LIFECYCLE, host-runnable. Wrong here = two worktrees boot
// the same serial and force-stop each other's app, or a passing run reaps a kept emulator.
void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('slot-lease-test'));
  tearDown(() => root.deleteSync(recursive: true));

  EmulatorProc frostsnap(int pid, int port) =>
      EmulatorProc(pid: pid, avd: 'frostsnap_sim_pool_0', port: port);
  EmulatorProc foreign(int pid, int port) =>
      EmulatorProc(pid: pid, avd: 'my_personal_avd', port: port);

  File lockFile(int slot) => File('${root.path}/test-slot-$slot.lock');
  void writeLock(int slot, {required int owner, required String mode}) =>
      lockFile(slot).writeAsStringSync(
        jsonEncode({'pid': owner, 'mode': mode, 'since': 'x'}),
      );

  SlotLeaser leaser({
    Set<int> alive = const {},
    List<EmulatorProc> procs = const [],
    List<String>? reaps,
    List<String>? progress,
  }) => SlotLeaser(
    root: root,
    slotCount: 2,
    pidAlive: alive.contains,
    processTable: () async => procs,
    reapOrphan: (s) async => reaps?.add(s),
    wait: (_) async {},
    onProgress: (m) => progress?.add(m),
  );

  test('parseSlotWait accepts positive seconds, rejects the rest', () {
    expect(parseSlotWait('45').$1, const Duration(seconds: 45));
    expect(parseSlotWait('0').$2, contains('positive integer'));
    expect(parseSlotWait('-3').$2, contains('positive integer'));
    expect(parseSlotWait('abc').$2, contains('abc'));
  });

  test('slotSerials reserves BOTH serials of the slot stride', () {
    expect(slotSerials(0), ['emulator-5582', 'emulator-5584']);
  });

  test('empty root → slot 0, lock written with mode normal', () async {
    final lease = await leaser().claim();
    expect(lease.slot, 0);
    final meta =
        jsonDecode(lockFile(0).readAsStringSync()) as Map<String, dynamic>;
    expect(meta['mode'], 'normal');
    expect(meta['pid'], pid);
  });

  test('a LIVE owner is never stolen', () async {
    writeLock(0, owner: 111, mode: 'normal');
    final lease = await leaser(alive: {111}).claim();
    expect(lease.slot, 1);
    expect(
      (jsonDecode(lockFile(0).readAsStringSync()) as Map)['pid'],
      111,
      reason: 'the live owner keeps its lock',
    );
  });

  test(
    'stale NORMAL owner + frostsnap orphan → orphan reaped BEFORE the lease is handed out',
    () async {
      writeLock(0, owner: 222, mode: 'normal');
      final reaps = <String>[];
      final lease = await leaser(
        procs: [frostsnap(900, 5582)],
        reaps: reaps,
      ).claim();
      expect(lease.slot, 0);
      expect(reaps, ['emulator-5582']);
    },
  );

  test(
    'stale KEEP owner + live frostsnap qemu → slot OCCUPIED, record kept, nothing reaped',
    () async {
      writeLock(0, owner: 222, mode: 'keep');
      final reaps = <String>[];
      final lease = await leaser(
        procs: [frostsnap(900, 5582)],
        reaps: reaps,
      ).claim();
      expect(lease.slot, 1);
      expect(reaps, isEmpty);
      expect(
        (jsonDecode(lockFile(0).readAsStringSync()) as Map)['mode'],
        'keep',
        reason: 'the keep reservation survives a passing claim',
      );
    },
  );

  test('KEEP record with nothing running is reclaimable', () async {
    writeLock(0, owner: 222, mode: 'keep');
    final lease = await leaser().claim();
    expect(lease.slot, 0);
  });

  test(
    'NO lock + live frostsnap qemu → fail safe: skipped, untouched',
    () async {
      final reaps = <String>[];
      final lease = await leaser(
        procs: [frostsnap(900, 5582)],
        reaps: reaps,
      ).claim();
      expect(lease.slot, 1);
      expect(reaps, isEmpty);
    },
  );

  test('NO lock + FOREIGN holder → skipped, untouched', () async {
    final reaps = <String>[];
    final lease = await leaser(
      procs: [foreign(901, 5584)],
      reaps: reaps,
    ).claim();
    expect(lease.slot, 1);
    expect(reaps, isEmpty);
  });

  test(
    'stale NORMAL metadata + FOREIGN holder → skipped, foreign never reaped',
    () async {
      writeLock(0, owner: 222, mode: 'normal');
      final reaps = <String>[];
      final lease = await leaser(
        procs: [foreign(901, 5582)],
        reaps: reaps,
      ).claim();
      expect(lease.slot, 1);
      expect(reaps, isEmpty);
    },
  );

  test('malformed metadata + live qemu → skipped, untouched', () async {
    lockFile(0).writeAsStringSync('not json at all');
    final reaps = <String>[];
    final lease = await leaser(
      procs: [frostsnap(900, 5582)],
      reaps: reaps,
    ).claim();
    expect(lease.slot, 1);
    expect(reaps, isEmpty);
  });

  test('malformed + nothing alive + past write grace → reclaimed', () async {
    lockFile(0).writeAsStringSync('garbage');
    lockFile(
      0,
    ).setLastModifiedSync(DateTime.now().subtract(const Duration(minutes: 5)));
    final lease = await leaser().claim();
    expect(lease.slot, 0);
  });

  test(
    'all busy → bounded wait, progress lines, then error naming holders',
    () async {
      writeLock(0, owner: 111, mode: 'normal');
      writeLock(1, owner: 112, mode: 'keep');
      final progress = <String>[];
      Object? err;
      try {
        await leaser(alive: {111, 112}, progress: progress).claim(
          waitBudget: const Duration(seconds: 4),
          pollEvery: const Duration(seconds: 2),
        );
      } catch (e) {
        err = e;
      }
      expect(progress, isNotEmpty);
      expect('$err', contains('no free test slot'));
      expect('$err', contains('111'));
      expect('$err', contains('keep'));
    },
  );

  group('runLeased (exception-safe disposition)', () {
    test('success: body, then reap, then release — in that order', () async {
      final lease = await leaser().claim();
      final events = <String>[];
      final out = await runLeased(
        lease: lease,
        keep: false,
        reapSlot: (s) async => events.add('reap $s'),
        body: () async {
          events.add('body');
          return 42;
        },
      );
      expect(out, 42);
      expect(events, ['body', 'reap 0']);
      expect(lockFile(0).existsSync(), isFalse, reason: 'released after reap');
    });

    test(
      'throwing body STILL reaps then releases; body error rethrown',
      () async {
        final lease = await leaser().claim();
        final events = <String>[];
        Object? err;
        try {
          await runLeased<void>(
            lease: lease,
            keep: false,
            reapSlot: (s) async => events.add('reap $s'),
            body: () async => throw StateError('setup exploded'),
          );
        } catch (e) {
          err = e;
        }
        expect(events, ['reap 0']);
        expect(lockFile(0).existsSync(), isFalse);
        expect('$err', contains('setup exploded'));
      },
    );

    test(
      'throwing body + failed reap leaves the lock HELD, reports both',
      () async {
        final lease = await leaser().claim();
        Object? err;
        try {
          await runLeased<void>(
            lease: lease,
            keep: false,
            reapSlot: (_) async => throw StateError('emulator survived'),
            body: () async => throw StateError('setup exploded'),
          );
        } catch (e) {
          err = e;
        }
        expect(
          lockFile(0).existsSync(),
          isTrue,
          reason: 'unconfirmed reap keeps the lease',
        );
        expect('$err', contains('setup exploded'));
        expect('$err', contains('emulator survived'));
      },
    );

    test(
      'success + failed reap leaves the lock and throws the cleanup error',
      () async {
        final lease = await leaser().claim();
        Object? err;
        try {
          await runLeased(
            lease: lease,
            keep: false,
            reapSlot: (_) async => throw StateError('emulator survived'),
            body: () async => 1,
          );
        } catch (e) {
          err = e;
        }
        expect(lockFile(0).existsSync(), isTrue);
        expect('$err', contains('emulator survived'));
      },
    );

    test(
      'keep mode persists the reservation even on an exceptional exit',
      () async {
        final lease = await leaser().claim();
        Object? err;
        try {
          await runLeased<void>(
            lease: lease,
            keep: true,
            reapSlot: (_) async => fail('keep mode must not reap'),
            body: () async => throw StateError('boom after boot'),
          );
        } catch (e) {
          err = e;
        }
        expect(
          (jsonDecode(lockFile(0).readAsStringSync()) as Map)['mode'],
          'keep',
        );
        expect('$err', contains('boom after boot'));
      },
    );

    test('null lease (host path): body passthrough, nothing touched', () async {
      expect(
        await runLeased(
          lease: null,
          keep: false,
          reapSlot: (_) async => fail('no lease, no reap'),
          body: () async => 'ok',
        ),
        'ok',
      );
    });
  });

  test('release deletes; persistKeep leaves an occupancy record', () async {
    final lease = await leaser().claim();
    lease.persistKeep();
    expect((jsonDecode(lockFile(0).readAsStringSync()) as Map)['mode'], 'keep');
    // A later run with the kept emulator alive skips the slot even though the owner pid is dead.
    final next = await leaser(procs: [frostsnap(900, 5582)]).claim();
    expect(next.slot, 1);
    next.release();
    expect(lockFile(1).existsSync(), isFalse);
  });
}
