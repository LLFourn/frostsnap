# fsim-emulator-lifecycle

Make emulator teardown DETERMINISTIC (every kill blocks until the qemu process is actually gone) and
AVD creation DRIFT-PROOF (an AVD created on an old system image is recreated when `sysImage` moves).
Emulator state reporting comes from the PROCESS TABLE, not adb's laggy cache.

## Why

`killEmulator` is fire-and-forget `adb emu kill` (`emulator.dart:190`), so every caller returns while
qemu is still dying. Observed consequences, all this branch:
- `./fsim down` prints `{"ok":true,"down":true}` while `adb devices` still lists the emulator for
  seconds — a reviewer cannot assert cleanup deterministically (the original feedback item).
- During a red `fsim test --android --jobs 2` run, second-wave tests attached to first-wave emulators
  that were still dying on the same slot ports — 40s "boots" that were really reuses of half-dead
  instances, producing garbage failure modes.
- `SIM_KEEP_EMULATOR=1 fsim test keygen --android` did NOT keep the emulator (it was gone right after
  the run) — the keep contract only demonstrably holds on the `--record-failures` rerun path.

Separately, `ensureAvd` (`emulator.dart:70-90`) early-returns if `~/.android/avd/<avd>.ini` EXISTS —
it never checks WHAT the AVD is. When `sysImage` moved to android-34, interactive-slot AVDs silently
stayed on android-30; fsim-android-ime-text's first validation ran on the wrong OS image because of
exactly this skew. Existence is the wrong invariant; image-match is the real one.

## Scope

### Deterministic kill — `test_driver/emulator.dart`
- `killEmulator(sdk, serial)` BLOCKS until dead: send `adb emu kill`, then poll until no qemu process
  owns the serial's port (the emulator embeds `-port <p>` in its argv; serial = `emulator-<p>`), with
  a bounded deadline (~30s). On deadline: SIGKILL the matching process, poll again briefly, then
  throw if it still survives. Idempotent: nothing running → immediate return. All existing callers
  (tearDown `sim_harness.dart:1866`, provision-failure cleanup `:379`, down/clean `fsim.dart:223`,
  `_reapSlotEmulators` `:1165`) inherit the blocking behavior. Blocking alone is NOT enough for two
  of the acceptances, though — two call sites have wrong POLICY, fixed below.

### Runner keep policy — `fsim.dart`
- The runner reaps the slot's emulators unconditionally after every android test (`:1067-1069`) — it
  would kill a kept emulator moments after the child honored `SIM_KEEP_EMULATOR=1`.
- Keep is a SINGLE-TEST post-mortem tool, and the surface enforces that scope at parse time (exit 2,
  distinct stderr messages): rejected unless exactly ONE test is selected (a second test on the same
  worker slot would boot the same deterministic serial into the kept emulator), rejected with
  `--retries N>0` (attempt 2 collides with attempt 1's kept emulator the same way), and rejected with
  `--record-failures` (the diagnostic rerun boots slot 0 itself). In the one valid shape — one test,
  no rerun modes — the runner skips `_reapSlotEmulators` for that test (the belt-and-suspenders reap
  is for orphans; a kept emulator is not an orphan).
- Pure policy helper (with the parser module) deciding reject-vs-keep-vs-reap from
  (env, selectedTestCount, retries, recordFailures) — the committed policy regression (tests below).

### `down` replies only after cleanup — `fsim.dart`
- Today the daemon writes+flushes `{"down":true}` and only THEN runs `shutdown()` (`:1931-1936`);
  `shutdown` swallows every `tearDown` error (`:1867-1874`), `AppSession.tearDown` itself swallows
  kill failure (`sim_harness.dart:1896-1899`), and the recovery serial file is deleted regardless —
  so even a blocking kill can't make `down:true` MEAN gone through this path.
- Reorder + propagate: run the FULL cleanup first, accumulating per-resource errors while still
  tearing down every remaining resource; build the reply from the completed result — `{"ok":true,
  "down":true}` only when no errors, else `{"ok":false,"errors":[…]}` (the `down` client exits
  nonzero on it). An emulator that survived the kill is an error, not a shrug.
- The recovery serial file is deleted ONLY when the emulator's death was confirmed; on an
  unconfirmed kill it stays, so a later `clean`/`info` can still find the orphan.
- Factor the orchestration into a testable seam (same module): run ALL labeled cleanups, collect
  labeled errors in order — the reply is DERIVED from that completed result, so response-ordering
  holds by construction and is unit-testable without a daemon.
- Shutdown becomes SINGLE-OWNER (and idempotent): the `appExitCode` watcher — the zombie-daemon
  guard that calls `shutdown()` + `exit(0)` when the app dies — would otherwise fire MID-`down`
  (the down cleanup tears the app down, resolving the watcher) and terminate the daemon before the
  reply is written. A small coordinator seam: the first claimant runs the cleanup, later claimants
  await the same result; the watcher only `exit(0)`s when IT won the claim — when the `down` handler
  owns the shutdown, the process exits on the down path AFTER the reply has been flushed.
- Pure helper for the process-table view (unit-testable): parse `ps`/pgrep output lines into
  `{pid, avd, port, serial}` records for `qemu-system*` processes with `-avd`/`-port` args. The kill
  poll and the `info` report below both consume it.

### AVD image drift — `test_driver/emulator.dart`
- `ensureAvd` verifies an EXISTING AVD's image: read `~/.android/avd/<avd>.avd/config.ini` and
  compare `image.sysdir.1` against the current `sysImage` path. Mismatch → delete the AVD (the
  `.avd` dir + `.ini`) and recreate on the current image; log one line saying why. Pure helper
  `avdImageMatches(configIni, sysImage)` (string in, bool out) for unit tests.

### Process-table status — `fsim.dart`
- Extend `fsim info` (existing verb — no new CLI surface) with an `emulators` field sourced from the
  process table via the pure parser: `[{serial, avd, port, pid}]`. Reports ALL frostsnap_sim_pool
  emulators (a stale one from a crashed run is exactly what you want to see), independent of adb.
- `down`'s reply is derived from the COMPLETED cleanup (see the down section): `"down":true` means
  gone; a surviving emulator yields `{"ok":false,"errors":[…]}`.

### Tests
- Unit (`frostsnapp/test/emulator_lifecycle_test.dart`): the process-line parser (qemu lines with
  -avd/-port → records; non-emulator lines ignored; port→serial mapping); `avdImageMatches`
  (android-34 path matches, android-30 → false, missing key → false/recreate); the keep policy
  (keep + one test → no runner reap; keep + multiple tests / + retries / + --record-failures → each
  its usage error; default → reap); the cleanup orchestrator (one failing cleanup doesn't skip the
  rest; labeled errors in order; empty on success; the reply derived from a failing result is
  non-success; serial-file retention decided by kill confirmation); the shutdown coordinator (single
  winner; second claimant awaits the same result; a non-owning watcher never exits early — the exit
  callback fires only for the owner).
- e2e acceptance below (live, no committed android suite additions).

## Acceptance
- `./fsim up --android && ./fsim down`: the instant `down` returns, `pgrep -f "qemu.*-port <port>"`
  is empty and `adb devices` does not list the serial. No sleep needed by the caller.
- After `fsim test keygen --android` (pass or fail), no qemu process remains.
- `SIM_KEEP_EMULATOR=1 fsim test keygen --android` leaves the emulator RUNNING (then reap manually) —
  the keep contract holds on the direct path, not just the record-failures rerun.
- `SIM_KEEP_EMULATOR=1 fsim test keygen --android --retries 1` → exit 2 with the keep/retries message;
  same env with TWO selected tests, or with `--record-failures` → exit 2 with their own messages.
- `./fsim up --android && ./fsim down` always delivers the full JSON reply — the app dying during
  cleanup (which resolves the zombie-daemon watcher) can no longer terminate the daemon first.
- `down` with an emulator that refuses to die → non-success reply listing the kill error, recovery
  serial file retained (unit-level via the orchestrator seam; the live happy path is the first bullet).
- `fsim info` with an android daemon up lists the emulator with its real pid; with none, `emulators`
  is empty even if adb's cache is stale.
- Doctor a pool AVD's config.ini to `android-30`, run any android bring-up: the AVD is recreated on
  the current image (one log line), and boots.
- `flutter test test/emulator_lifecycle_test.dart` green; `dart analyze test_driver test` clean; host
  suite untouched.
