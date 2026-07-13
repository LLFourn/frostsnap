// Android emulator LIFECYCLE primitives (ensure-AVD / boot / provision / wait / kill), keyed by
// (avd, port, serial) with NO pool/slot knowledge — extracted from the runner (fsim.dart) so the
// TEST PROCESS can provision its own emulator(s) too, behind the app-instance seam (sim-unify-app-host).
// Every function takes the resolved Android SDK root [sdk]; callers own AVD naming and port assignment.

import 'dart:async';
import 'dart:io';

import 'emulator_lifecycle.dart';

bool hostArchIsArm() {
  try {
    return (Process.runSync('uname', ['-m']).stdout as String).trim() ==
        'arm64';
  } catch (_) {
    return false;
  }
}

String get sysImage =>
    'system-images;android-34;google_apis;${hostArchIsArm() ? 'arm64-v8a' : 'x86_64'}';

/// Run [exe] inheriting stdio; throw on non-zero exit.
Future<void> runInheritStdio(String exe, List<String> args) async {
  final p = await Process.start(exe, args, mode: ProcessStartMode.inheritStdio);
  if (await p.exitCode != 0) {
    throw StateError('command failed: $exe ${args.join(' ')}');
  }
}

/// Run [exe] feeding [stdinText] to its stdin (for the sdkmanager/avdmanager license/profile prompts);
/// log (don't throw) on non-zero exit.
Future<void> runFeeding(String exe, List<String> args, String stdinText) async {
  final p = await Process.start(exe, args);
  p.stdin.write(stdinText);
  await p.stdin.close();
  unawaited(stdout.addStream(p.stdout));
  unawaited(stderr.addStream(p.stderr));
  final code = await p.exitCode;
  if (code != 0) {
    stderr.writeln('fsim: `$exe ${args.first}` exited $code (continuing)');
  }
}

/// Install the emulator package + system image once (idempotent; gated on the image already being
/// present, so per-AVD callers don't re-run the slow check). The first run is a large download.
Future<void> ensureSdkPackages(String sdk) async {
  final abi = hostArchIsArm() ? 'arm64-v8a' : 'x86_64';
  if (File('$sdk/emulator/emulator').existsSync() &&
      Directory(
        '$sdk/system-images/android-34/google_apis/$abi',
      ).existsSync()) {
    return;
  }
  final sdkmanager = '$sdk/cmdline-tools/latest/bin/sdkmanager';
  stderr.writeln(
    'fsim: provisioning emulator + $sysImage (one-time, large download) …',
  );
  // Accept any pending licenses, then install (feeding "y" covers per-package license prompts).
  await runFeeding(sdkmanager, ['--licenses'], 'y\n' * 50);
  await runFeeding(sdkmanager, [
    '--install',
    'emulator',
    'platform-tools',
    sysImage,
  ], 'y\n' * 50);
}

/// Ensure AVD [avd] exists ON THE CURRENT SYSTEM IMAGE, installing the SDK packages first if
/// needed. Idempotent. Existence alone is the wrong invariant: when [sysImage] moves (android-30 →
/// android-34), an existing AVD silently stays on the old OS — image-match is checked and a stale
/// AVD is recreated (fsim-android-ime-text's first validation ran on the wrong image because of
/// exactly this drift).
Future<String> ensureAvd(String sdk, String avd) async {
  final home = Platform.environment['HOME'];
  final avdIni = '$home/.android/avd/$avd.ini';
  final avdDir = '$home/.android/avd/$avd.avd';
  if (File(avdIni).existsSync()) {
    final config = File('$avdDir/config.ini');
    if (config.existsSync() &&
        avdImageMatches(config.readAsStringSync(), sysImage)) {
      return avd;
    }
    stderr.writeln(
      'fsim: AVD "$avd" is on a stale system image — recreating on $sysImage',
    );
    try {
      File(avdIni).deleteSync();
    } catch (_) {}
    try {
      Directory(avdDir).deleteSync(recursive: true);
    } catch (_) {}
  }
  await ensureSdkPackages(sdk);
  final avdmanager = '$sdk/cmdline-tools/latest/bin/avdmanager';
  stderr.writeln('fsim: creating AVD "$avd" …');
  // "no" declines the custom-hardware-profile prompt.
  await runFeeding(avdmanager, [
    'create',
    'avd',
    '-n',
    avd,
    '-k',
    sysImage,
    '--device',
    'pixel_6',
    '--force',
  ], 'no\n');
  return avd;
}

/// Put a booted emulator into the state the sim needs, BEFORE the app launches. Best-effort and
/// idempotent (it runs on every bring-up, reused emulator or fresh boot):
///   - a secure lock-screen PIN (0000) — Frostsnap requires a secure lock, as it keystores secrets
///     behind device authentication;
///   - the device left UNLOCKED and kept awake — a locked device gives the app no focused window,
///     which ANRs it on launch ("Input dispatching timed out"); `stayon` stops it re-locking during
///     the slow build/launch;
///   - 3-button navigation — the app draws edge-to-edge, so the nav bar overlapping content is
///     exactly the case we want exercised (a common source of safe-area bugs).
Future<void> provisionEmulator(String sdk, String serial) async {
  final adb = '$sdk/platform-tools/adb';
  Future<void> sh(List<String> cmd) =>
      Process.run(adb, ['-s', serial, 'shell', ...cmd]);

  // Keep the screen awake so the device can't sleep + re-lock during the build/launch.
  await sh(['svc', 'power', 'stayon', 'true']);
  await sh(['input', 'keyevent', 'KEYCODE_WAKEUP']);
  // Unlock past the keyguard. Feed the PIN to the bouncer ONLY when the device is actually locked (a
  // secure PIN set AND the keyguard engaged) — `dumpsys trust` reports `deviceLocked=1` exactly then.
  // Typing it unconditionally was a bug: on a fresh emulator (no PIN, keyguard already dismissed) the
  // `0000` has no PIN field, so it lands on whatever IS focused — the launcher's Google search box —
  // and fires a stray web search. `deviceLocked` is 0 for an insecure/already-unlocked device, so the
  // guard correctly skips it there and only types into a real bouncer.
  await sh(['wm', 'dismiss-keyguard']);
  final trust = await Process.run(adb, [
    '-s',
    serial,
    'shell',
    'dumpsys',
    'trust',
  ]);
  if ((trust.stdout as String).contains('deviceLocked=1')) {
    await sh(['input', 'text', '0000']);
    await sh(['input', 'keyevent', 'KEYCODE_ENTER']);
  }
  // Set the PIN while unlocked + awake, so it's configured but the session stays unlocked (a no-op
  // exit if one already exists). This is REQUIRED, not cosmetic: the app's SecureKeyManager
  // (getOrCreateKey) fails fast with NO_LOCK_SCREEN unless `isDeviceSecure`, because its signing key
  // is `setUserAuthenticationRequired(true)` — so the sim can't keygen/sign without a secure lock.
  await sh(['locksettings', 'set-pin', '0000']);
  // enable-exclusive --category disables the other nav-bar overlays (gestural/two-button) so we
  // land on three-button cleanly rather than leaving several enabled.
  await sh([
    'cmd',
    'overlay',
    'enable-exclusive',
    '--category',
    'com.android.internal.systemui.navbar.threebutton',
  ]);
}

/// adb wait-for-device + poll `sys.boot_completed` for the SPECIFIC [serial] (every emulator boots on
/// a known fixed port, so we always target one device). Targeting matters: an untargeted poll fails
/// with "more than one device" once several emulators run concurrently.
Future<void> waitForBoot(String sdk, String serial) async {
  final adb = '$sdk/platform-tools/adb';
  await runInheritStdio(adb, ['-s', serial, 'wait-for-device']);
  final deadline = DateTime.now().add(const Duration(minutes: 5));
  while (DateTime.now().isBefore(deadline)) {
    final r = await Process.run(adb, [
      '-s',
      serial,
      'shell',
      'getprop',
      'sys.boot_completed',
    ]);
    if ((r.stdout as String).trim() == '1') return;
    await Future<void>.delayed(const Duration(seconds: 2));
  }
  throw StateError('emulator $serial did not finish booting within 5 minutes');
}

/// Cold-boot [avd] on [port] (detached, clean state) and wait until it has finished booting; returns
/// its serial (`emulator-$port` — the emulator assigns the serial from `-port`). Does NOT provision:
/// callers call [provisionEmulator] separately (they also provision an already-running/reused emulator).
/// `-wipe-data` cold-boots a CLEAN package DB — repeated `flutter run` installs otherwise corrupt a
/// long-lived emulator's package state so the launcher activity stops resolving and the app never
/// launches (bring-up then dies on the VM-service timeout).
Future<String> bootEmulator(
  String sdk, {
  required String avd,
  required int port,
}) async {
  final serial = 'emulator-$port';
  await Process.start('$sdk/emulator/emulator', [
    '-avd',
    avd,
    '-port',
    '$port',
    '-no-snapshot',
    '-wipe-data',
    '-no-boot-anim',
    '-gpu',
    'auto',
  ], mode: ProcessStartMode.detached);
  await waitForBoot(sdk, serial);
  return serial;
}

/// ALL live qemu emulator processes, from the PROCESS TABLE (adb's device cache lags a dying
/// emulator by seconds — the process is the truth). FAIL-CLOSED: a failing `ps` throws instead of
/// reading as "no emulators" (an empty table is what tells a caller an emulator is DEAD).
/// [runPs] is injectable for the failure-path unit test. Callers that only want OUR emulators
/// filter on [EmulatorProc.isFrostsnap].
Future<List<EmulatorProc>> liveEmulators({
  Future<ProcessResult> Function()? runPs,
}) async {
  final ps =
      await (runPs ?? () => Process.run('ps', ['-axo', 'pid=,command=']))();
  if (ps.exitCode != 0) {
    throw StateError(
      'ps failed (${ps.exitCode}): ${(ps.stderr as String).trim()} — cannot read the process table',
    );
  }
  return parseEmulatorProcesses((ps.stdout as String).split('\n'));
}

/// Kill the emulator [serial] and BLOCK until its qemu process is actually gone (idempotent — an
/// immediate no-op if it isn't running). `adb emu kill` is fire-and-forget, so callers that trusted
/// it returned while qemu was still dying: `down` reported success early, and the next test on the
/// slot attached to a half-dead instance. Poll the process table (~30s); on deadline SIGKILL the
/// pid; still alive briefly after that → throw. A FOREIGN qemu on our serial's port is a collision,
/// not a target: refuse to touch it and throw.
Future<void> killEmulator(String sdk, String serial) async {
  Future<EmulatorProc?> holder() async =>
      portOwner(await liveEmulators(), serial);

  final original = await holder();
  if (original == null) return;
  if (!original.isFrostsnap) {
    throw StateError(
      'serial $serial is held by a non-frostsnap emulator (avd "${original.avd}", pid ${original.pid}) '
      '— refusing to kill a foreign process; free the port or use another slot',
    );
  }
  // Every subsequent observation is judged by PID IDENTITY against [original]: ownership is not
  // stable across the wait — our qemu can exit and another process can acquire the port between
  // polls, and the fallback must never signal such a replacement.
  Never reoccupied(EmulatorProc now) => throw StateError(
    'serial $serial: the original emulator (pid ${original.pid}) is gone but the port was '
    'REOCCUPIED by avd "${now.avd}" (pid ${now.pid}) mid-kill — the slot is not clean',
  );
  await Process.run('$sdk/platform-tools/adb', ['-s', serial, 'emu', 'kill']);
  final graceful = DateTime.now().add(const Duration(seconds: 30));
  while (DateTime.now().isBefore(graceful)) {
    final now = await holder();
    switch (classifyKillPoll(originalPid: original.pid, holder: now)) {
      case KillPoll.gone:
        return;
      case KillPoll.reoccupied:
        reoccupied(now!);
      case KillPoll.stillOriginal:
        await Future<void>.delayed(const Duration(milliseconds: 500));
    }
  }
  final atDeadline = await holder();
  final target = sigkillTarget(originalPid: original.pid, holder: atDeadline);
  if (target == null) {
    if (atDeadline == null) return;
    reoccupied(atDeadline);
  }
  Process.killPid(target, ProcessSignal.sigkill);
  final forced = DateTime.now().add(const Duration(seconds: 5));
  while (DateTime.now().isBefore(forced)) {
    final now = await holder();
    switch (classifyKillPoll(originalPid: original.pid, holder: now)) {
      case KillPoll.gone:
        return;
      case KillPoll.reoccupied:
        reoccupied(now!);
      case KillPoll.stillOriginal:
        await Future<void>.delayed(const Duration(milliseconds: 250));
    }
  }
  throw StateError(
    'emulator $serial (pid ${original.pid}) survived `adb emu kill` + SIGKILL',
  );
}

/// Max app instances ONE slot provisions — the FIXED per-slot stride, so an emulator's port/AVD/serial never
/// collides across concurrent slots OR instances. `deviceIndex = globalSlot * maxInstancesPerTest + instance`.
const maxInstancesPerTest = 2;

/// The GLOBAL slot space is PARTITIONED so interactive `up` sessions and concurrent test workers never share
/// an emulator: test workers take slots `[0, maxTestWorkers)`; interactive sessions take
/// `[maxTestWorkers, maxTestWorkers + maxInteractiveSessions)` (see [interactiveGlobalSlot]). Every emulator —
/// test OR interactive — is named by the ONE scheme below ([emulatorPort]/[emulatorAvd] over its deviceIndex);
/// there is no separate interactive range. The whole partition must fit the console-port ceiling
/// ([maxConsolePort]): `emulatorPort((maxTestWorkers + maxInteractiveSessions) * maxInstancesPerTest - 1)` =
/// 5676 ≤ 5682, so up to 16 concurrent test workers + 8 interactive sessions coexist without collision.
const maxTestWorkers = 16;
const maxInteractiveSessions = 8;

/// Deterministic emulator PORT for a device index. Clear of the legacy interactive emulator's 5554, and 2
/// apart so each index gets a distinct serial (`emulator-$port`, from `-port`).
const emulatorBasePort = 5582;
int emulatorPort(int deviceIndex) => emulatorBasePort + deviceIndex * 2;

/// Deterministic serial for a device index (`emulator-$port` — the emulator assigns it from `-port`).
String emulatorSerial(int deviceIndex) =>
    'emulator-${emulatorPort(deviceIndex)}';

/// Deterministic AVD name for a device index — NAME-isolated from the legacy interactive `frostsnap_sim` AVD.
String emulatorAvd(int deviceIndex) => 'frostsnap_sim_pool_$deviceIndex';

/// The GLOBAL slot for interactive `up` session slot [s] (0-based), placed ABOVE the test workers' range
/// `[0, maxTestWorkers)` so an interactive session and a concurrent test run never share an emulator.
int interactiveGlobalSlot(int s) => maxTestWorkers + s;

/// The Android emulator console-port ceiling (even ports 5554–5682). A slot claim beyond its range must error
/// clearly rather than derive a port past this.
const maxConsolePort = 5682;
