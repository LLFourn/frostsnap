# fsim-test-worktree-isolation

`fsim test` worker slots become MACHINE-GLOBAL leases: two worktrees (or any two concurrent runs)
can no longer boot/reap the same deterministic emulator serial and force-stop each other's app —
and a KEPT emulator's slot reads as OCCUPIED, not as stale garbage to reclaim.

## Why

Test workers use process-local slot indices (worker 0 always boots `emulator-5582`, etc.), while the
emulator pool, ports, AVDs, and the single `com.frostsnap` package are machine-global. Interactive
`fsim up` already claims a machine-global slot lock; `fsim test` does not — so concurrent runs from
two worktrees collide: one run's install/reap `am force-stop`s the other's app mid-test ("the app
closed and I have no idea why", per the PR-505 feedback; plausibly also this branch's vanished
kept-emulator mystery). Same-process workers never collide (distinct slots); the cross-PROCESS case
is unprotected. (The parallel-android-tests work is FINISHED on this branch — 8470cf7d is an
ancestor — and did not add cross-process claiming; this plan is the concrete delta against the
current runner + the interactive lock code.)

## Scope — `frostsnapp/test_driver/fsim.dart` + a lease module

### TestSlotLease — machine-global, metadata-bearing, held THROUGH cleanup
- Built on the interactive lock's REAL primitives (`fsim.dart:1615-1673`): atomic exclusive-create
  under `$TMPDIR/frostsnap-sim`, staleness by owner-PID liveness (SIGCONT probe) plus a write-grace
  for empty files. The OS does NOT drop these on death — reclamation is explicit, so the lease
  models it explicitly.
- `TestSlotLease.claim(...)` scans the test-worker slot range and returns the ACTUAL claimed slot
  (workers use `lease.slot` for ports/AVDs/serials — one slot covers BOTH of its
  `maxInstancesPerTest` serials, so multi-instance tests are reserved by construction). The lock
  file records JSON metadata `{pid, mode: normal|keep, since}` — a bare PID cannot distinguish a
  dead keep-owner (occupied slot) from a dead normal owner (reclaimable).
- Lease lifetime: claimed BEFORE boot/provision, held across retries, released in a `finally` only
  AFTER the confirmed `_reapSlotEmulators` — reap-then-release; release-before-reap would let
  another worktree boot into a still-dying emulator.
- KEEP runs: SIM_KEEP_EMULATOR has TWO meanings and the lease uses the RUNNER's top-level validated
  policy, never the child env — a top-level keep run (single-test shape) rewrites its lease file as
  `mode: keep` on exit (persistent occupancy record for the surviving emulator), while the
  `--record-failures` rerun sets SIM_KEEP_EMULATOR only in its CHILD (so the recorder can pull the
  mp4) and its lease owner still reaps and RELEASES afterward (transient keep, no reservation).
  Covered by a wiring/policy test.
- RECONCILE on EVERY claim (fresh exclusive-create AND stale reclaim alike): the process table and
  the lease file JOINTLY define ownership — a slot can host a live qemu with NO lock at all (a kept
  emulator from before this change, a manually-removed lock, a crash mid-metadata-write), and a
  fresh create must not treat that as clean. After the atomic claim, inspect BOTH of the slot's
  deterministic serials — inspecting ANY qemu holder (liveEmulators deliberately retains foreign
  AVDs; a non-frostsnap qemu can hold our serial):
  - FOREIGN holder on either port → always OCCUPIED/collision: preserve it, skip the slot, and name
    its pid + AVD in the contention output — consistent with killEmulator's refuse-to-touch-foreign
    guarantee, caught at allocation instead of mid-boot.
  - frostsnap holder + prior lease proving a DEAD NORMAL owner → orphan: reap it (blocking,
    identity-tracked `killEmulator`) before reuse.
  - frostsnap holder + anything else (`mode: keep`; NO lock; malformed/empty metadata) → FAIL SAFE:
    the slot is OCCUPIED — release the just-created lock (or preserve/re-write the keep record) and
    skip to the next slot. Never boot over or reap a process whose ownership isn't proven
    stale-normal.
  - nothing alive → clean reuse.
- Contention: every slot busy → bounded wait (poll ~2s, default 120s, `--slot-wait SECS` to change)
  with a progress line naming each slot's owner pid + mode; on timeout the runner EXITS NONZERO
  with a clear error naming the holders — it never proceeds into a collision.

### Every boot path claims
- Normal workers: claim before the test child launches; `workerSlot` becomes `lease.slot`.
- `--record-failures` diagnostic reruns hard-code slot 0 today (`fsim.dart:1164-1183`) — they
  acquire the SAME lease (any free slot; the recorder targets `lease.slot`'s serial) so the
  post-batch phase can't collide with another worktree either.
- Interactive `up` keeps its existing lock unchanged (disjoint slot ranges).

### Tests — the LOCK LIFECYCLE, host-runnable (pure index-picking proves nothing)
- Lease tests against real lock files in a temp root (injectable) with injectable process-liveness
  and process-table seams:
  - a LIVE owner is never stolen;
  - stale NORMAL owner → reclaimed, and the orphan-reap hook is invoked BEFORE the lease is handed
    out;
  - stale KEEP owner with a live qemu on the slot serial → slot skipped, keep record preserved;
  - release only after cleanup: the reap hook observably runs before the lock file disappears;
  - all-busy → bounded-wait then the error outcome (injected clock/poll);
  - NO lock + live frostsnap qemu on a slot serial → slot skipped, the process untouched;
  - malformed/empty lock metadata + live qemu → slot skipped, the process untouched;
  - NO lock + FOREIGN qemu holder → slot skipped, the process untouched;
  - stale-normal metadata + FOREIGN holder → slot skipped, the foreign process never reaped.
- `--slot-wait` is user surface: parser/usage tests committed (invalid value rejected, default
  documented), and the `fsim test` help text gains the flag with its default and the exits-nonzero
  timeout behavior.

### e2e acceptance evidence (not the review gate — the committed tests above are)
- TWO concurrent `fsim test keygen --android` runs from two directories both green, each on its own
  serial (different ports in their logs); afterwards a third run claims slot 0 again.
- A `SIM_KEEP_EMULATOR` single-test run, then a run from another directory: the kept slot is
  SKIPPED (the second run boots the next slot) and the kept emulator survives untouched.

## Acceptance
- The committed lease/reconciliation lifecycle tests green; `dart analyze test_driver test` clean.
- A single run's behavior is unchanged (claims slot 0 when free; timing ± lock overhead).
- The dual-run and kept-occupancy live evidence above.
