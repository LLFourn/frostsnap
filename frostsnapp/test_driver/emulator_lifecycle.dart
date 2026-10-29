// fsim-emulator-lifecycle: the pure decision/parsing logic behind deterministic emulator teardown.
// The process table (not adb's laggy cache) is the source of truth for "is it running"; the keep
// policy scopes SIM_KEEP_EMULATOR to the one shape that can't collide; the cleanup orchestrator +
// exit gate make `down`'s reply mean what it says. Integration lives in emulator.dart / fsim.dart.

import 'dart:async';

/// One live emulator process, parsed from the process table.
class EmulatorProc {
  final int pid;
  final String avd;
  final int port;
  EmulatorProc({required this.pid, required this.avd, required this.port});
  String get serial => 'emulator-$port';

  /// Whether this is OUR emulator. Reporting and killing are restricted to frostsnap AVDs — a
  /// user's unrelated qemu must never be listed as ours, let alone SIGKILLed.
  bool get isFrostsnap => avd.startsWith('frostsnap_sim_');
}

/// Who owns [serial]'s port right now: our emulator, a FOREIGN qemu (collision — refuse to touch
/// it), or nobody.
EmulatorProc? portOwner(List<EmulatorProc> procs, String serial) {
  for (final p in procs) {
    if (p.serial == serial) return p;
  }
  return null;
}

/// Parse `ps -axo pid=,command=` lines into the qemu emulator processes (command contains
/// `qemu-system` and carries `-avd <name>` + `-port <n>`). Everything else is ignored.
List<EmulatorProc> parseEmulatorProcesses(Iterable<String> psLines) {
  final procs = <EmulatorProc>[];
  for (final line in psLines) {
    final t = line.trim();
    if (t.isEmpty || !t.contains('qemu-system')) continue;
    final parts = t.split(RegExp(r'\s+'));
    final pid = int.tryParse(parts.first);
    if (pid == null) continue;
    String? avd;
    int? port;
    for (var i = 1; i < parts.length - 1; i++) {
      if (parts[i] == '-avd') avd = parts[i + 1];
      if (parts[i] == '-port') port = int.tryParse(parts[i + 1]);
    }
    if (avd == null || port == null) continue;
    procs.add(EmulatorProc(pid: pid, avd: avd, port: port));
  }
  return procs;
}

/// Whether an existing AVD's config.ini is on the CURRENT system image. [sysImage] is the sdkmanager
/// path (`system-images;android-34;google_apis;arm64-v8a`); the config records it as
/// `image.sysdir.1=system-images/android-34/google_apis/arm64-v8a/`. Missing key → false (recreate).
bool avdImageMatches(String configIni, String sysImage) {
  final want = sysImage.replaceAll(';', '/');
  for (final line in configIni.split('\n')) {
    final m = RegExp(r'^\s*image\.sysdir\.1\s*=\s*(.+?)\s*$').firstMatch(line);
    if (m != null) {
      final have = m.group(1)!.replaceAll(RegExp(r'/+$'), '');
      return have == want;
    }
  }
  return false;
}

/// Why this SIM_KEEP_EMULATOR run shape is rejected, or null if it's the ONE collision-free shape:
/// exactly one selected test, no rerun modes. (A second test on the worker slot, a retry attempt, or
/// the --record-failures rerun would each boot the kept emulator's deterministic serial.)
String? keepEmulatorUsageError({
  required bool keep,
  required int selectedTests,
  required int retries,
  required bool recordFailures,
}) {
  if (!keep) return null;
  if (selectedTests != 1) {
    return 'fsim test: SIM_KEEP_EMULATOR=1 needs exactly ONE selected test '
        '(got $selectedTests) — a second test on the worker slot would boot into the kept emulator';
  }
  if (retries > 0) {
    return 'fsim test: SIM_KEEP_EMULATOR=1 is incompatible with --retries — a retry attempt would '
        'boot into the kept emulator on the same slot serial';
  }
  if (recordFailures) {
    return 'fsim test: SIM_KEEP_EMULATOR=1 is incompatible with --record-failures — the diagnostic '
        're-run boots the slot itself';
  }
  return null;
}

/// Run EVERY labeled cleanup in order, never letting one failure skip the rest; returns the labeled
/// errors, in order (empty = full success). `down`'s reply is DERIVED from this completed result, so
/// "down":true structurally cannot be written before cleanup finished.
Future<List<String>> runCleanups(
  List<(String, Future<void> Function())> cleanups,
) async {
  final errors = <String>[];
  for (final (label, run) in cleanups) {
    try {
      await run();
    } catch (e) {
      errors.add('$label: $e');
    }
  }
  return errors;
}

/// One observation of the port during a kill wait, judged against the ORIGINAL owned process.
/// Ownership is NOT stable across the wait: our qemu can exit and another AVD can acquire the port
/// between polls — every step must re-establish IDENTITY (pid), not just occupancy.
enum KillPoll {
  /// Nobody holds the port — the original is confirmed gone.
  gone,

  /// The original process still holds the port.
  stillOriginal,

  /// A DIFFERENT process holds the port now: the original is gone, but the slot is NOT clean —
  /// report a collision; never signal the replacement.
  reoccupied,
}

KillPoll classifyKillPoll({
  required int originalPid,
  required EmulatorProc? holder,
}) {
  if (holder == null) return KillPoll.gone;
  return holder.pid == originalPid
      ? KillPoll.stillOriginal
      : KillPoll.reoccupied;
}

/// The pid the deadline fallback may SIGKILL: the ORIGINAL, and only while it still holds the port.
/// Null = nothing is safe to signal (gone, or the port was reoccupied by another process — killing
/// the current holder would destroy a process we do not own).
int? sigkillTarget({required int originalPid, required EmulatorProc? holder}) =>
    classifyKillPoll(originalPid: originalPid, holder: holder) ==
        KillPoll.stillOriginal
    ? originalPid
    : null;

/// Whether tearDown kills this session's emulator. The ONLY inputs are the session's own state —
/// deliberately no environment parameter: keep-mode is an explicit seam policy set by the
/// runner-validated test path, and an ambient env read here is how `SIM_KEEP_EMULATOR=1 fsim up`
/// once made a later `down` silently skip the kill.
bool shouldKillEmulatorOnTearDown({
  required String? serial,
  required bool keepEmulator,
}) => serial != null && !keepEmulator;

/// Reap every serial in [serials] via [kill], attempting ALL of them regardless of failures, then
/// THROW an aggregate if any kill was unconfirmed. Swallowing a survivor here is how a worker slot
/// got reused by the next test while a half-dead emulator still held its port — an unconfirmed reap
/// must stop the consumer, not be a stderr shrug.
Future<void> reapSerials(
  Iterable<String> serials,
  Future<void> Function(String serial) kill,
) async {
  final errors = <String>[];
  for (final serial in serials) {
    try {
      await kill(serial);
    } catch (e) {
      errors.add('$serial: $e');
    }
  }
  if (errors.isNotEmpty) {
    throw StateError('emulator reap unconfirmed — ${errors.join('; ')}');
  }
}

/// Exit gate between the `down` handler and the daemon's self-shutdown watchers (app-death, signals).
/// Cleanup itself is already single-run (the shared shutdown future); the remaining race is
/// `exit(0)`: a watcher resolved BY the down-initiated teardown must not terminate the process before
/// the down reply is flushed. The handler holds the gate across cleanup+reply; watchers pass through
/// [whenClear] before exiting.
class ShutdownExitGate {
  Completer<void>? _held;

  /// The `down` handler claims the gate before starting cleanup. Idempotent.
  void hold() => _held ??= Completer<void>();

  /// Release after the reply has been flushed. Idempotent; harmless if never held.
  void release() {
    if (!(_held?.isCompleted ?? true)) _held!.complete();
  }

  /// Resolves once no reply is pending — immediately if the gate was never held.
  Future<void> whenClear() => _held?.future ?? Future.value();
}
