# master-red-typist-and-analyze
# Fork master is red on two counts from this branch's work

Both plans you finished were folded into the fork's stack commit and published to
`LLFourn/frostsnap:master` as `6d42d364`. The push-triggered CI came back **red**:

**Run 31349205763** — https://github.com/LLFourn/frostsnap/actions/runs/31349205763

| job | result |
|---|---|
| `Build Device Firmware` (legacy **and** frontier) | **pass** |
| `Build app for` Android / Linux / macOS / Windows, `Package AppImage` | pass |
| `Test ordinary libraries` | **FAIL** |
| `Flutter Analyze` | **FAIL** |

The firmware half is genuinely fixed — that gate had been red since 2026-08-07 and a restack onto current
upstream (#532) cleared it. The two below are what remain.

## 1. `Flutter Analyze` — a concrete compile break, and the easy one

```
error • 7 positional arguments expected by 'AppSession.new', but 6 found
      • test/label_diagnostics_test.dart:202:15 • not_enough_positional_arguments
1 issue found.
error: recipe `lint-app` failed on line 318 with exit code 1
```

`[harness-startup-reliability]` gave `AppSession` a 7th positional parameter (`this._liveness`) and
`frostsnapp/test/label_diagnostics_test.dart:202` still constructs it with 6.

**This is not a call-site tweak, which is why it is yours rather than something I patched.** `_AppLiveness`
is library-private to `sim_harness.dart`, so the test cannot name or construct one. It needs an API
decision — an optional parameter defaulting to a fresh `_AppLiveness()`, a named test constructor, or
something better. Pick the one that keeps the test meaningful; do not weaken what it asserts to make the
signature fit.

Worth asking while you are there: your record said "analyze, formatter, and unit tests clean". `just
lint-app` is what CI runs and it covers `frostsnapp/test/`. Whatever you ran did not. Closing that gap is
probably worth more than this one fix.

## 2. `backup_typist` — still failing, and the diagnosis is NOT foreclosed

```
thread 'backup_typist::tests::types_a_backup_on_a_running_device_through_the_protocol'
panicked at tools/virtual_device/src/backup_typist.rs: typing on the device failed:
entered words resolved to an invalid checksum
test result: FAILED. 42 passed; 1 failed
```

Same symptom as before the fix. **This does not prove the settled-surface mechanism was wrong.** A second,
independent dropped-input path would produce an identical invalid checksum, and your analysis of the
`EntryView`-leads-the-surface race was sound on its own terms. Treat this as "still red under CI, here is
the run" rather than "your fix was wrong" — the honest reading is that the fix may be correct and
incomplete.

What is new and valuable: **you now have the CI failure you never had.** The original plan noted 11
oversubscribed local runs that never reproduced it, and I later added 5 more clean runs plus a 14/14 suite
pass on this machine — so local reproduction has failed 30-odd times and CI reproduces it readily. That
asymmetry is itself the strongest lead. CI runs the binary in ~10.5s against this machine's ~74s.

## Constraints

- **No `#[ignore]`, no retry, no loosened assertion.** A green master bought that way is worse than the
  honest red, and the typist is a dependency of `typeBackup()` in the e2e drivers — an instrument that
  drops presses under load will do it there too, where it gets blamed on whatever feature is under test.
- **No WHAT comments.** Only WHY, and only when the why isn't obvious from the code.
- **Prefer no test to a mocked one.**
- Before calling either fixed, run what CI runs, not an approximation:
  `just lint-app` and `just test-ordinary --release --all-features --locked`.
  I made exactly that mistake — I verified the publication with an android e2e, which never compiles
  `frostsnapp/test/*` and never runs `test-ordinary`, so both of these failures were invisible to me while
  being reachable locally in minutes.
