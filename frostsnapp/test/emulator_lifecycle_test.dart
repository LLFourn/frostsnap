import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../test_driver/emulator.dart' show liveEmulators;
import '../test_driver/emulator_lifecycle.dart';

// fsim-emulator-lifecycle: the pure logic behind deterministic teardown. The parser is the kill
// poll's source of truth (wrong = kills nothing or the wrong pid); the keep policy is the
// collision guard; the orchestrator + gate are why `down:true` means gone and the reply always
// arrives.
void main() {
  group('parseEmulatorProcesses', () {
    test('extracts pid/avd/port from qemu lines, ignores everything else', () {
      final procs = parseEmulatorProcesses([
        '  123 /sdk/emulator/qemu/darwin-aarch64/qemu-system-aarch64 -avd frostsnap_sim_pool_0 -port 5582 -no-snapshot -wipe-data',
        ' 4567 /opt/homebrew/bin/limactl usernet -p something', // not qemu
        '  890 /sdk/emulator/qemu/darwin-aarch64/qemu-system-aarch64 -avd frostsnap_sim_pool_32 -port 5646 -gpu auto',
        'garbage line',
        '',
      ]);
      expect(procs, hasLength(2));
      expect(procs[0].pid, 123);
      expect(procs[0].avd, 'frostsnap_sim_pool_0');
      expect(procs[0].port, 5582);
      expect(procs[0].serial, 'emulator-5582');
      expect(procs[1].serial, 'emulator-5646');
    });

    test('qemu line missing -avd or -port is ignored', () {
      expect(
        parseEmulatorProcesses([
          ' 11 qemu-system-aarch64 -port 5582',
          ' 12 qemu-system-aarch64 -avd x',
        ]),
        isEmpty,
      );
    });
  });

  group('avdImageMatches', () {
    const sysImage = 'system-images;android-34;google_apis;arm64-v8a';

    test('matching image path (with trailing slash) matches', () {
      expect(
        avdImageMatches(
          'hw.cpu.arch=arm64\nimage.sysdir.1=system-images/android-34/google_apis/arm64-v8a/\ntarget=android-34',
          sysImage,
        ),
        isTrue,
      );
    });

    test('a stale android-30 AVD does not match', () {
      expect(
        avdImageMatches(
          'image.sysdir.1=system-images/android-30/google_apis/arm64-v8a/',
          sysImage,
        ),
        isFalse,
      );
    });

    test('missing key means recreate (false)', () {
      expect(avdImageMatches('hw.cpu.arch=arm64', sysImage), isFalse);
    });
  });

  group('keepEmulatorUsageError', () {
    test('keep off is always fine', () {
      expect(
        keepEmulatorUsageError(
          keep: false,
          selectedTests: 7,
          retries: 3,
          recordFailures: true,
        ),
        isNull,
      );
    });

    test('the one valid shape: one test, no rerun modes', () {
      expect(
        keepEmulatorUsageError(
          keep: true,
          selectedTests: 1,
          retries: 0,
          recordFailures: false,
        ),
        isNull,
      );
    });

    test('multiple selected tests are rejected', () {
      final err = keepEmulatorUsageError(
        keep: true,
        selectedTests: 7,
        retries: 0,
        recordFailures: false,
      );
      expect(err, contains('exactly ONE selected test'));
    });

    test('retries are rejected', () {
      final err = keepEmulatorUsageError(
        keep: true,
        selectedTests: 1,
        retries: 2,
        recordFailures: false,
      );
      expect(err, contains('--retries'));
    });

    test('record-failures is rejected', () {
      final err = keepEmulatorUsageError(
        keep: true,
        selectedTests: 1,
        retries: 0,
        recordFailures: true,
      );
      expect(err, contains('--record-failures'));
    });
  });

  group('ownership', () {
    test('a foreign qemu AVD is parsed but never counted as ours', () {
      final procs = parseEmulatorProcesses([
        ' 10 qemu-system-aarch64 -avd frostsnap_sim_pool_0 -port 5582',
        ' 11 qemu-system-aarch64 -avd my_personal_avd -port 5584',
      ]);
      expect(procs, hasLength(2));
      expect(procs[0].isFrostsnap, isTrue);
      expect(procs[1].isFrostsnap, isFalse);
    });

    test('portOwner finds the exact serial holder, ours or foreign', () {
      final procs = parseEmulatorProcesses([
        ' 10 qemu-system-aarch64 -avd frostsnap_sim_pool_0 -port 5582',
        ' 11 qemu-system-aarch64 -avd my_personal_avd -port 5584',
      ]);
      expect(portOwner(procs, 'emulator-5582')!.isFrostsnap, isTrue);
      expect(portOwner(procs, 'emulator-5584')!.isFrostsnap, isFalse);
      expect(portOwner(procs, 'emulator-5586'), isNull);
    });
  });

  group('kill identity (owned → foreign port handoff)', () {
    EmulatorProc proc(int pid, String avd, int port) => parseEmulatorProcesses([
      ' $pid qemu-system-aarch64 -avd $avd -port $port',
    ]).single;

    test('classifyKillPoll tracks the ORIGINAL pid, not port occupancy', () {
      final original = proc(100, 'frostsnap_sim_pool_0', 5582);
      expect(
        classifyKillPoll(originalPid: original.pid, holder: null),
        KillPoll.gone,
      );
      expect(
        classifyKillPoll(originalPid: original.pid, holder: original),
        KillPoll.stillOriginal,
      );
      // The handoff: our qemu exited, a FOREIGN AVD grabbed the port between polls.
      expect(
        classifyKillPoll(
          originalPid: original.pid,
          holder: proc(200, 'my_personal_avd', 5582),
        ),
        KillPoll.reoccupied,
      );
      // Same for a different frostsnap process (another worker's boot): identity, not name.
      expect(
        classifyKillPoll(
          originalPid: original.pid,
          holder: proc(300, 'frostsnap_sim_pool_0', 5582),
        ),
        KillPoll.reoccupied,
      );
    });

    test('the SIGKILL fallback never targets a replacement holder', () {
      expect(
        sigkillTarget(
          originalPid: 100,
          holder: proc(100, 'frostsnap_sim_pool_0', 5582),
        ),
        100,
      );
      expect(
        sigkillTarget(
          originalPid: 100,
          holder: proc(200, 'my_personal_avd', 5582),
        ),
        isNull,
        reason: 'owned → foreign handoff: nothing is safe to signal',
      );
      expect(sigkillTarget(originalPid: 100, holder: null), isNull);
    });
  });

  group('reapSerials', () {
    test('attempts every serial, then throws the aggregate', () async {
      final killed = <String>[];
      Object? err;
      try {
        await reapSerials(['a', 'b', 'c'], (s) async {
          killed.add(s);
          if (s != 'b') throw StateError('$s survived');
        });
      } catch (e) {
        err = e;
      }
      expect(killed, ['a', 'b', 'c'], reason: 'no serial may be skipped');
      expect('$err', contains('a: '));
      expect('$err', contains('c: '));
      expect('$err', contains('unconfirmed'));
    });

    test('all confirmed → no throw', () async {
      await reapSerials(['a', 'b'], (_) async {});
    });
  });

  group('runCleanups', () {
    test(
      'a failing cleanup never skips the rest; errors are labeled in order',
      () async {
        final ran = <String>[];
        final errors = await runCleanups([
          ('a', () async => ran.add('a')),
          ('b', () async => throw StateError('boom-b')),
          ('c', () async => ran.add('c')),
          ('d', () async => throw StateError('boom-d')),
        ]);
        expect(ran, ['a', 'c']);
        expect(errors, hasLength(2));
        expect(errors[0], startsWith('b: '));
        expect(errors[0], contains('boom-b'));
        expect(errors[1], startsWith('d: '));
      },
    );

    test('full success returns no errors', () async {
      expect(await runCleanups([('x', () async {})]), isEmpty);
    });
  });

  group('liveEmulators (injected ps)', () {
    test('a failing ps is an ERROR, never an empty table', () async {
      // Fail-open here reads as "the emulator is dead" to the kill poll — the false success that
      // let a dying emulator's slot be reused.
      expect(
        liveEmulators(
          runPs: () async => ProcessResult(1, 2, '', 'ps: cannot fork'),
        ),
        throwsStateError,
      );
    });

    test('a healthy ps parses the table', () async {
      final procs = await liveEmulators(
        runPs: () async => ProcessResult(
          1,
          0,
          ' 10 qemu-system-aarch64 -avd frostsnap_sim_pool_0 -port 5582\n',
          '',
        ),
      );
      expect(procs.single.serial, 'emulator-5582');
    });
  });

  group('shouldKillEmulatorOnTearDown', () {
    // The signature admits NO environment — keep-mode reaches teardown only as the explicit seam
    // policy, so `SIM_KEEP_EMULATOR=1 fsim up` can never make a later `down` skip the kill.
    test('android session, no keep → kill', () {
      expect(
        shouldKillEmulatorOnTearDown(
          serial: 'emulator-5582',
          keepEmulator: false,
        ),
        isTrue,
      );
    });

    test('keep set by the validated test path → no kill', () {
      expect(
        shouldKillEmulatorOnTearDown(
          serial: 'emulator-5582',
          keepEmulator: true,
        ),
        isFalse,
      );
    });

    test('host session (no serial) → nothing to kill', () {
      expect(
        shouldKillEmulatorOnTearDown(serial: null, keepEmulator: false),
        isFalse,
      );
    });
  });

  group('ShutdownExitGate', () {
    test('a watcher passes immediately when the gate was never held', () async {
      var exited = false;
      await ShutdownExitGate().whenClear().then((_) => exited = true);
      expect(exited, isTrue);
    });

    test('a held gate defers the watcher exit until release', () async {
      final gate = ShutdownExitGate();
      gate.hold();
      var exited = false;
      unawaited(gate.whenClear().then((_) => exited = true));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(exited, isFalse, reason: 'reply still pending — must not exit');
      gate.release();
      await Future<void>.delayed(Duration.zero);
      expect(exited, isTrue);
    });

    test('hold and release are idempotent', () async {
      final gate = ShutdownExitGate();
      gate.hold();
      gate.hold();
      gate.release();
      gate.release();
      await gate.whenClear();
    });
  });
}
