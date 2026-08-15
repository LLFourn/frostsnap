# sim-pool-self-heal

The Android emulator pool claims a slot with an **exclusive lockfile**: `_claimSlot(cap)`
(`frostsnapp/test_driver/simctl.dart`) creates `slot-N.lock` in `_poolDir()` for the lowest free
`N` in `[0, cap)`, and `_releaseSlot(slot)` deletes it. `_claimSlot` decides a slot is busy purely
by lockfile **existence** — it never checks whether an emulator is actually running behind it. So the
moment a run fails to reach `_releaseSlot` — a killed/interrupted runner, an uncaught exception, a
reaped test — the lockfile persists with no emulator behind it, and every later `--android` run sees
the slot as busy: `_acquireEmulator` throws `emulator pool exhausted (cap N)`, and the whole run dies
at 0.0s with "could not boot ANY pool emulator". Recovery today requires a manual `./simctl pool reset`.

Observed: two stale `slot-N.lock` claims (emulator-5582/5584) with **zero** live emulators
(`adb devices` empty, no `qemu-system` process) blocked a fresh `--jobs 1 --android` run until a
manual reset.

Goal: a stale claim (a lockfile with no live owner) can NEVER block a run. The pool self-heals by
reconciling dead claims before acquiring, so `pool reset` is a convenience, never a requirement.

## Tasks

### Task 1 — Make a claim self-describe its owner, and reconcile dead ones
- Stamp each `slot-N.lock` with the **claiming runner's PID** (and the slot's serial) instead of an
  empty lockfile. The owner is the `dart run simctl.dart` process that called `_claimSlot`.
- Define STALE: a lock whose owner PID is no longer alive — the runner that made it died/was killed
  without releasing, so it can never release. (A live runner mid-cold-boot has a live PID, so a
  booting slot is never mistaken for stale — this is why the liveness signal is the owner PID, not
  `adb devices`, which a booting emulator hasn't joined yet.)
- `_claimSlot` reclaims a stale lock (delete + re-create exclusively) before returning "exhausted",
  so a leaked claim self-heals on the very next acquire. Keep the exclusive-create atomicity so two
  workers racing to reclaim the same slot can't both win.
- Guard against PID reuse (a dead runner's PID recycled by an unrelated process): also record a
  timestamp and/or verify the live PID is actually a dart/simctl process before treating a lock as
  live; when unsure, prefer reclaiming an obviously-dead slot (no emulator + old timestamp) over
  leaving the pool wedged.

### Task 2 — Release on every exit path + expose reconcile
- In `_runAndroidPool`, wrap acquire → run → teardown so `_releaseSlot` runs on EVERY worker exit:
  success, test FAILED, TIMEOUT/reap, and exception (a `finally`). This stops within-run leaks at the
  source; Task 1 remains the guarantee for the un-cleanable case (a SIGKILL'd runner can't run
  `finally`).
- Add `simctl pool reconcile` — drop dead claims and report which slots/serials it reclaimed — and
  have `simctl test --android` reconcile once at startup so a poisoned pool self-clears before any
  worker boots.
- `simctl pool status` should mark each claim live vs stale (owner PID alive? serial in `adb
  devices`?) so the state is legible without guessing.

### Task 3 — Regression test
- Self-heal: seed a stale claim (write a `slot-0.lock` stamped with a dead/bogus PID, no emulator) and
  assert the next acquire (or `simctl test --android` startup reconcile) RECLAIMS it and proceeds.
  This fails against today's existence-only `_claimSlot` (which would report exhausted).
- No false eviction: a lock owned by a LIVE PID must NOT be reclaimed.
- Keep the core host-runnable: the lock-staleness/reconcile logic is testable against the PID liveness
  check with no real emulator (stub the liveness predicate). One `--android` smoke confirms end-to-end
  that a pre-seeded stale claim no longer blocks a boot.

## Non-goals
- Changing the pool cap, `--jobs`, or the parallelism model.
- The per-session regtest backend lifecycle (separate; already reaped by process group).
- A long-lived pool daemon — the pool stays file-lock based, just liveness-aware.
- Cross-host / shared-CI pool coordination.
