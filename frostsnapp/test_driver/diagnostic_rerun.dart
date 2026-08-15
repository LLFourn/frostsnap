// Failure-video diagnostics for `fsim test --record-failures` (fsim-failure-video): after the batch
// completes, each final failure is re-run ONCE, solo, with a screen recorder bracketing the child. The
// re-run never changes a verdict — the runner freezes its results before this phase runs. This module
// holds the pure decision logic (unit-tested) and the recorder backends; the orchestration lives in
// fsim.dart (it needs the private test types).

import 'dart:async';
import 'dart:io';

/// Parse-time validation: recording is ANDROID-ONLY (the emulator's `screenrecord`, driven from any
/// host OS) — there is no host recorder. Returns the usage error, or null if ok.
String? recordFailuresUsageError({required bool android}) {
  if (!android) {
    return 'fsim test: --record-failures is android-only (emulator screenrecord) — add --android';
  }
  return null;
}

/// The final failures to re-run, in batch order. Pure selection — never mutates [results]; the caller
/// runs the re-runs SEQUENTIALLY so each records solo.
List<T> selectDiagnosticReruns<T>(
  List<T> results,
  bool enabled,
  bool Function(T) isFinalFailure,
) {
  if (!enabled) return const [];
  return results.where(isFinalFailure).toList();
}

/// The pulled segments that actually CONTAIN video — a successful `Process.start`/pull is no evidence
/// screenrecord produced a clip, so only existing, non-empty host files count.
Future<List<String>> usableSegments(List<String> paths) async {
  final usable = <String>[];
  for (final p in paths) {
    final f = File(p);
    if (await f.exists() && await f.length() > 0) usable.add(p);
  }
  return usable;
}

/// Run [action] over [items] ONE AT A TIME in order — the diagnostic re-runs must each record solo. A
/// failing item is handed to [onError] and never prevents the remaining items (the phase is diagnostic:
/// an escaping exception would change fsim's exit code).
Future<void> runSequentially<T>(
  List<T> items,
  Future<void> Function(T) action,
  void Function(T, Object) onError,
) async {
  for (final item in items) {
    try {
      await action(item);
    } catch (e) {
      onError(item, e);
    }
  }
}

// ---- android screenrecord segments ----

/// Poll `sys.boot_completed` on [serial] until the emulator has FULLY booted, the child finishes first
/// (no emulator to record), or [limit] passes. The diagnostic child SELF-BOOTS its emulator, and
/// screenrecord needs a fully-booted device — adbd answers well before /sdcard and SurfaceFlinger are up,
/// so an adb-reachable probe starts the recorder too early and it dies without writing a file.
Future<bool> waitBootCompleted(
  String adb,
  String serial,
  Future<void> childDone, {
  Duration poll = const Duration(seconds: 2),
  Duration limit = const Duration(minutes: 8),
}) async {
  var childFinished = false;
  unawaited(childDone.whenComplete(() => childFinished = true));
  final deadline = DateTime.now().add(limit);
  while (!childFinished && DateTime.now().isBefore(deadline)) {
    try {
      final r = await Process.run(adb, [
        '-s',
        serial,
        'shell',
        'getprop',
        'sys.boot_completed',
      ]).timeout(poll * 3);
      if (r.exitCode == 0 && (r.stdout as String).trim() == '1') return true;
    } catch (_) {}
    await Future<void>.delayed(poll);
  }
  return false;
}

/// Chained `screenrecord` segments on [serial] (the device caps each at 180s). [start] spawns the
/// segment loop; [stopAndPull] SIGINTs the live segment (finalizing its mp4), pulls every segment to
/// `<destDir>/rerun-N.mp4`, and removes the device files.
class AndroidSegmentRecorder {
  final String adb;
  final String serial;
  final _deviceFiles = <String>[];
  Future<void>? _loop;
  var _stopping = false;

  AndroidSegmentRecorder({required this.adb, required this.serial});

  void start() => _loop = _segmentLoop();

  Future<void> _segmentLoop() async {
    var earlyFails = 0;
    for (var n = 0; !_stopping;) {
      // /data/local/tmp, NOT /sdcard: right after sys.boot_completed the FUSE /sdcard mount is briefly
      // still read-only ("Operation not permitted"), while /data/local/tmp is shell-writable from boot.
      final file = '/data/local/tmp/fsim-rerun-$n.mp4';
      final sw = Stopwatch()..start();
      final proc = await Process.start(adb, [
        '-s',
        serial,
        'shell',
        'screenrecord',
        '--time-limit',
        '180',
        file,
      ]);
      proc.stdout.drain<void>();
      proc.stderr.drain<void>();
      await proc.exitCode;
      // An instantly-dead segment means screenrecord itself failed (device still settling, or gone) —
      // retry briefly rather than spinning forever OR giving up on a device that needs a few more seconds.
      if (sw.elapsed < const Duration(seconds: 2) && !_stopping) {
        if (++earlyFails > 10) break;
        await Future<void>.delayed(const Duration(seconds: 2));
        continue;
      }
      earlyFails = 0;
      _deviceFiles.add(file);
      n++;
    }
  }

  Future<List<String>> stopAndPull(String destDir) async {
    _stopping = true;
    await Process.run(adb, [
      '-s',
      serial,
      'shell',
      'pkill',
      '-INT',
      'screenrecord',
    ]);
    // Await the LOOP, not just the current process — it appends the final (pkill-finalized) segment to
    // _deviceFiles after that segment's exit.
    await _loop?.timeout(const Duration(seconds: 15), onTimeout: () {});
    final pulled = <String>[];
    for (var n = 0; n < _deviceFiles.length; n++) {
      final host = '$destDir/rerun-$n.mp4';
      final pull = await Process.run(adb, [
        '-s',
        serial,
        'pull',
        _deviceFiles[n],
        host,
      ]);
      if (pull.exitCode == 0) {
        pulled.add(host);
      } else {
        stderr.writeln(
          'fsim: --record-failures: pull of ${_deviceFiles[n]} failed: '
          '${(pull.stderr as String).trim()}',
        );
      }
      await Process.run(adb, [
        '-s',
        serial,
        'shell',
        'rm',
        '-f',
        _deviceFiles[n],
      ]);
    }
    return pulled;
  }
}
