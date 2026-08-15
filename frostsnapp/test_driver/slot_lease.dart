// fsim-test-worktree-isolation: machine-global TEST slot leases. Worker slots are process-local
// indices today, but the emulator pool (ports/AVDs/serials) and the single com.frostsnap package
// are machine-global — two worktrees' runs boot/reap each other's emulators and force-stop each
// other's app. Built on the same primitives as the interactive slot lock (atomic exclusive-create;
// staleness by owner-PID liveness — the OS does NOT drop these files on death), plus what a bare
// PID file cannot express: metadata distinguishing a dead KEEP owner (occupied reservation) from a
// dead NORMAL owner (reclaimable), and process-table occupancy on EVERY claim.

import 'dart:convert';
import 'dart:io';

import 'emulator.dart' show emulatorSerial, maxInstancesPerTest;
import 'emulator_lifecycle.dart' show EmulatorProc, portOwner;

/// Grace for an EMPTY/unparsable lock (created, but metadata not yet written) before it counts as
/// abandoned — mirrors the interactive lock's write grace.
const _leaseWriteGrace = Duration(seconds: 10);

/// One claimed test slot. Hold from BEFORE boot/provision until AFTER the confirmed slot reap —
/// reap-then-[release]; releasing first would let another worktree boot into a dying emulator.
class SlotLease {
  final int slot;
  final File _lock;
  SlotLease._(this.slot, this._lock);

  /// The deterministic serials this lease reserves (both instances of the slot's stride).
  List<String> get serials => slotSerials(slot);

  /// Normal disposition: delete the lock. Call only AFTER the slot's emulators are confirmed gone.
  void release() {
    try {
      _lock.deleteSync();
    } catch (_) {}
  }

  /// Keep disposition (top-level SIM_KEEP_EMULATOR run): the surviving emulator stays, so the lock
  /// becomes a persistent occupancy record instead of being deleted — a later claimer sees
  /// `mode: keep` + the live qemu and skips this slot.
  void persistKeep() {
    _lock.writeAsStringSync(
      jsonEncode({
        'pid': pid,
        'mode': 'keep',
        'since': DateTime.now().toIso8601String(),
      }),
    );
  }
}

/// Run [body] under [lease] with exactly ONE disposition on EVERY exit path — a bare happy-path
/// tail skips cleanup when the body throws (Process.start/setup failures), stranding a live-owner
/// lock + orphan for the rest of the batch.
/// - keep mode: [SlotLease.persistKeep] always, even on an exceptional exit after boot (the
///   emulator may be up — the reservation must exist either way).
/// - normal mode: the FULL slot reap first, [SlotLease.release] only after it succeeds; a failed
///   reap leaves the lease HELD (the slot stays locked while this pid lives; stale-normal
///   reclamation recovers it later).
/// Body and cleanup errors are both preserved — neither silently replaces the other.
Future<T> runLeased<T>({
  required SlotLease? lease,
  required bool keep,
  required Future<void> Function(int slot) reapSlot,
  required Future<T> Function() body,
}) async {
  if (lease == null) return body(); // host path: nothing to dispose
  T? result;
  Object? bodyErr;
  StackTrace? bodyStack;
  try {
    result = await body();
  } catch (e, st) {
    bodyErr = e;
    bodyStack = st;
  }
  Object? cleanupErr;
  try {
    if (keep) {
      lease.persistKeep();
    } else {
      await reapSlot(lease.slot);
      lease.release();
    }
  } catch (e) {
    cleanupErr = e;
  }
  if (bodyErr != null && cleanupErr != null) {
    throw StateError('$bodyErr; additionally slot cleanup failed: $cleanupErr');
  }
  if (bodyErr != null) Error.throwWithStackTrace(bodyErr, bodyStack!);
  if (cleanupErr != null) throw cleanupErr;
  return result as T;
}

/// Parse a `--slot-wait` seconds value: (duration, null) or (null, usage error).
(Duration?, String?) parseSlotWait(String value) {
  final secs = int.tryParse(value);
  if (secs == null || secs <= 0) {
    return (
      null,
      'fsim test: --slot-wait expects a positive integer of seconds, got "$value"',
    );
  }
  return (Duration(seconds: secs), null);
}

List<String> slotSerials(int slot) => [
  for (var i = 0; i < maxInstancesPerTest; i++)
    emulatorSerial(slot * maxInstancesPerTest + i),
];

/// Machine-global allocator for the test-worker slot range. Every IO edge is injectable so the
/// LOCK LIFECYCLE is host-testable: [pidAlive] (owner liveness), [processTable] (qemu occupancy),
/// [reapOrphan] (blocking identity-tracked kill), [wait] (contention clock).
class SlotLeaser {
  final Directory root;
  final int slotCount;
  final bool Function(int pid) pidAlive;
  final Future<List<EmulatorProc>> Function() processTable;
  final Future<void> Function(String serial) reapOrphan;
  final Future<void> Function(Duration) wait;
  final void Function(String) onProgress;

  SlotLeaser({
    required this.root,
    required this.slotCount,
    required this.pidAlive,
    required this.processTable,
    required this.reapOrphan,
    this.wait = Future.delayed,
    this.onProgress = _ignore,
  });

  static void _ignore(String _) {}

  File _lockFile(int slot) => File('${root.path}/test-slot-$slot.lock');

  /// Claim any free slot, waiting up to [waitBudget] when all are busy; throws [StateError] naming
  /// the holders on timeout — the runner exits nonzero rather than proceeding into a collision.
  Future<SlotLease> claim({
    Duration waitBudget = const Duration(seconds: 120),
    Duration pollEvery = const Duration(seconds: 2),
  }) async {
    var waited = Duration.zero;
    while (true) {
      final busy = <String>[];
      final lease = await _tryClaimAny(busy);
      if (lease != null) return lease;
      if (waited >= waitBudget) {
        throw StateError(
          'no free test slot after ${waitBudget.inSeconds}s — holders: ${busy.join('; ')} '
          '(raise --slot-wait, or reap/finish the runs holding them)',
        );
      }
      onProgress(
        'fsim: all test slots busy (${busy.join('; ')}) — waiting '
        '(${(waitBudget - waited).inSeconds}s left)…',
      );
      await wait(pollEvery);
      waited += pollEvery;
    }
  }

  Future<SlotLease?> _tryClaimAny(List<String> busy) async {
    for (var slot = 0; slot < slotCount; slot++) {
      final lease = await _tryClaim(slot, busy);
      if (lease != null) return lease;
    }
    return null;
  }

  Future<SlotLease?> _tryClaim(int slot, List<String> busy) async {
    final lock = _lockFile(slot);
    if (lock.existsSync()) {
      final meta = _readMeta(lock);
      if (meta == null) {
        // Unparsable/empty: a claimer mid-write, or garbage. Within the write grace it's busy;
        // past it, reclaim ONLY when nothing occupies the slot (fail safe).
        if (_youngerThanGrace(lock) || await _occupied(slot, busy, 'unowned')) {
          busy.add('slot $slot: unreadable lock');
          return null;
        }
        return _reclaim(slot, lock, busy);
      }
      if (pidAlive(meta.pid)) {
        busy.add('slot $slot: pid ${meta.pid} (${meta.mode})');
        return null;
      }
      if (meta.mode == 'keep') {
        // A dead keep-owner is the RESERVATION working as intended while its emulator lives; only
        // a keep record with nothing running is reclaimable.
        if (await _occupied(slot, busy, 'kept')) return null;
        return _reclaim(slot, lock, busy);
      }
      // Dead NORMAL owner: reclaim, then reap ONLY its proven-orphan frostsnap emulators.
      return _reclaim(slot, lock, busy, reapFrostsnapOrphans: true);
    }
    // No lock at all: claim atomically, then fail-safe occupancy (a live qemu with no lock — a
    // pre-lease kept emulator, a lost lock, a foreign process — is never booted over or reaped).
    if (!_create(lock)) {
      busy.add('slot $slot: lost the claim race');
      return null;
    }
    if (await _occupied(slot, busy, 'unowned')) {
      try {
        lock.deleteSync();
      } catch (_) {}
      return null;
    }
    return SlotLease._(slot, lock);
  }

  /// Whether any qemu holds one of [slot]'s serials. FOREIGN holders are always occupancy — the
  /// kill path refuses to touch them, so the allocator must refuse to hand their slot out.
  Future<bool> _occupied(int slot, List<String> busy, String why) async {
    final procs = await processTable();
    for (final serial in slotSerials(slot)) {
      final holder = portOwner(procs, serial);
      if (holder != null) {
        busy.add(
          'slot $slot: $why ${holder.isFrostsnap ? '' : 'FOREIGN '}emulator '
          '$serial (avd "${holder.avd}", pid ${holder.pid})',
        );
        return true;
      }
    }
    return false;
  }

  Future<SlotLease?> _reclaim(
    int slot,
    File lock,
    List<String> busy, {
    bool reapFrostsnapOrphans = false,
  }) async {
    try {
      lock.deleteSync();
    } catch (_) {}
    if (!_create(lock)) {
      busy.add('slot $slot: lost the reclaim race');
      return null;
    }
    if (reapFrostsnapOrphans) {
      final procs = await processTable();
      for (final serial in slotSerials(slot)) {
        final holder = portOwner(procs, serial);
        if (holder == null) continue;
        if (!holder.isFrostsnap) {
          // Foreign process on our port: collision, never a target.
          busy.add(
            'slot $slot: FOREIGN emulator $serial (avd "${holder.avd}", pid ${holder.pid})',
          );
          try {
            lock.deleteSync();
          } catch (_) {}
          return null;
        }
        // Proven orphan (its recorded normal owner is dead): reap BEFORE handing the slot out.
        await reapOrphan(serial);
      }
    } else if (await _occupied(slot, busy, 'unowned')) {
      try {
        lock.deleteSync();
      } catch (_) {}
      return null;
    }
    return SlotLease._(slot, lock);
  }

  bool _create(File lock) {
    try {
      lock.createSync(exclusive: true);
      lock.writeAsStringSync(
        jsonEncode({
          'pid': pid,
          'mode': 'normal',
          'since': DateTime.now().toIso8601String(),
        }),
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  bool _youngerThanGrace(File lock) {
    try {
      return DateTime.now().difference(lock.statSync().modified) <
          _leaseWriteGrace;
    } catch (_) {
      return true; // vanished mid-look — treat as busy, retry later
    }
  }

  ({int pid, String mode})? _readMeta(File lock) {
    try {
      final m = jsonDecode(lock.readAsStringSync()) as Map<String, dynamic>;
      final pid = m['pid'];
      final mode = m['mode'];
      if (pid is int && (mode == 'normal' || mode == 'keep')) {
        return (pid: pid, mode: mode as String);
      }
    } catch (_) {}
    return null;
  }
}
