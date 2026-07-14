# backup-typist-dropped-keypress
# The backup typist loses a keypress under load, and it is making fork master red

`backup_typist::tests::types_a_backup_on_a_running_device_through_the_protocol` panics in CI:

```
thread '…types_a_backup_on_a_running_device_through_the_protocol' panicked at
tools/virtual_device/src/backup_typist.rs:942:13:
typing on the device failed: entered words resolved to an invalid checksum
test result: FAILED. 41 passed; 1 failed
error: recipe `test-ordinary` failed on line 279 with exit code 101
```

It fails the **Test ordinary libraries** job (`just test-ordinary --release --all-features --locked`),
which is one of two reasons `LLFourn/frostsnap` master has been **red since 2026-08-07**. The other
(a device-firmware stack-check gate) is fixed by an upstream restack; this one is not, and it is yours
— the typist is `[fsim-paper-backup]`'s instrument.

## What the evidence already says — don't re-derive it

- **It is not a checksum-logic bug.** The suite deliberately models the invalid-checksum outcome in a
  neighbouring test (`checksum_invalid_words_type_through_and_resolve_invalid`), and that one passes. An
  invalid checksum *here* means the typed word sequence was not what the test intended — i.e. the typist
  dropped, duplicated or mis-ordered a keypress.
- **It is timing-dependent, not deterministic.** On the dev machine it passes: 14/14 across the whole
  `backup_typist` suite, plus 3/3 further targeted runs. Same commit, same flags
  (`--release --all-features --locked`).
- **The timing gap is itself the clue.** CI finishes the failing test binary in **10.55s**; the dev machine
  takes **~75s** for the same tests, and two of them log "has been running for over 60 seconds". A ~7x
  speed difference means CI is exercising a window this machine may simply never open. Explaining that
  discrepancy is probably the fastest route to the race.

## What to do

Find the actual race and fix it at the source. The typist drives the real on-screen keyboards through the
real protocol; somewhere between "press key" and "device observed the press" there is an assumption about
ordering or settling that holds at 75s and breaks at 10s.

## What NOT to do

- **Do not paper over it with a retry, a sleep, or a loosened assertion.** This instrument is a dependency
  of the e2e drivers (`typeBackup()` types all 26 rows). An instrument that silently drops presses under
  load will drop them there too, and those failures will be attributed to whatever feature is under test
  rather than to the typist. A retry converts a real intermittent defect into a green suite, which is the
  opposite of what an instrument should do.
- **Do not mark it `#[ignore]`.** That turns a red master into a green master with less coverage, which is
  strictly worse than the current honest red.

If after investigation the conclusion genuinely is "the test's timing assumption was wrong, not the
typist's behaviour", that is an acceptable answer — but say so explicitly and show why the instrument is
sound, rather than adjusting the test until it passes.

## Note on your local environment

CI pins **Flutter 3.38.5** (`frostsnapp/.fvmrc`); this machine has been running **3.41.7** with no fvm
installed. That does not affect this rust test, but it does mean local fsim greens have never established
pinned-CI behaviour in general. Worth knowing before you trust a local run as proof of anything.

## Constraints

- **No WHAT comments.** No comment that restates the code, paraphrases a function's own name, narrates a
  sequence, or carries PR/changelog meta. Only WHY, and only when the why isn't obvious. Test: delete the
  comment — if the code still says everything it said, leave it deleted.
- **Prefer no test to a mocked one.** The value here is that the typist drives a real device through the
  real protocol; a fix that mocks that away removes the only thing the test was proving.
