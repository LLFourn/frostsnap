# fsim-paper-backup
# fsim-paper-backup — full paper-backup e2e: type a backup on the device screen

## Why

We have no automated coverage of the paper-backup cycle — the single most
safety-critical user journey: *display* a share backup on the device, write it
down, and later *restore* it by typing it back in on a blank device's on-screen
keyboards. The entry UI (`EnterShareScreen`: numeric share-index keyboard,
BIP39-constrained alphabetic keyboard, word selector) is exactly the kind of
half-baked-by-its-own-admission code (`enter_share_screen.rs` line 1) that
needs a mechanical exerciser.

The deliverable is an **instrument that types a full backup, given its text
form, as real touches** — plus one e2e that runs the whole cycle through the
app.

## The contract: touches only, eyes read-only

- Every interaction with the device is a `TouchEvent` through the same
  `TouchQueue` → `touch_handler` path a finger takes. No injection API that
  feeds words into `BackupModel` directly (the existing `prefill_test_words`
  dev feature is not our path and is untouched).
- The instrument may *look* at the live UI (the analog of human eyes on the
  screen) but never mutate through that channel. This observation is
  **privileged**: it reads the whole backup text and the entry progress
  regardless of what one page currently shows — it is sim instrumentation,
  not a claim about pixel visibility.
- Key coordinates are never hard-coded in the sim. Each keyboard widget
  exports its own hit-geometry next to its layout code, pinned by tests that
  assert `handle_touch(claimed_point)` yields the claimed key.

## How entry works (drives the design)

`BackupModel` (already `pub` in `frostsnap_widgets`) is fully deterministic:

- Row 0: share index on `NumericKeyboard` — digits, then `✓` confirms.
- Each word: `EnterWord` mode on `AlphabeticKeyboard` while the typed prefix
  matches >8 BIP39 words ('Q' auto-appends 'U'); at ≤8 matches the screen
  switches to `WordSelect` — tap the word button to complete the row.
- After 25 words: `AllWordsEntered { success: Option<ShareBackup> }` —
  checksum-valid ⇒ 1 s success delay ⇒ finished; invalid ⇒ `Invalid` state
  with per-row edit.

Timing constraints the instrument must respect (why it is closed-loop, not
timer-paced): after every key action the screen ignores touches until the tap
animation fades (~100 ms) and the deferred model update applies on a draw;
`WordSelector` additionally ignores touches for a 200/400 ms grace after it
first draws.

Geometry constraints: the alphabetic keyboard is a fixed 4×7 grid of 60×50 px
keys (content 350 px) inside a 220 px viewport (240×280 screen minus the 60 px
input preview), so rows 5–6 (U–Z) require scrolling.

## Design

### 1. Hit-geometry contracts in `frostsnap_widgets`

Small `pub` helpers beside each widget's layout code, each with a pin test
(construct widget → `handle_touch` at the claimed point → assert the key):

- `AlphabeticKeyboard::letter_point(letter, scroll) -> Point` — closed-form
  grid math, same constants the renderer uses.
- `NumericKeyboard::key_point(key) -> Point` — digits, `✓`, `⌫`.
- `WordSelector::word_point(index, constraint_size) -> Point` — mirrors its
  own two-column SpaceEvenly construction, in the same file.
- `EnterShareScreen`: a read-only `view_state()` accessor (progress: row,
  cursor, mode) and the existing `is_finished()`/`get_backup()`.

Points are in each widget's local space; the screen-level offset
(`keyboard_rect` starts below the 60 px preview) is part of the typed plan.

### 2. `BackupTypist` in `tools/virtual_device`

`backup_typist.rs`: parses the target text **lexically** — exactly `#N`
(digits) plus 25 words, each required to be on the BIP39 list (the keyboards
cannot type anything else) — and deliberately does NOT construct a
`ShareBackup` from it. Checksum validity is judged only by the real
`BackupModel` on the device after the touches land; parsing via `ShareBackup`
up front would pre-validate the checksum and make the wrong-word path
untypeable. The instrument then drives a closed loop:

1. Replay a shadow `BackupModel` to know the expected mode + next key
   (digit / ✓ / letter / word-button index). The shadow is the *real* model —
   no re-implementation of entry logic (leaf-only invariant). The shadow
   predicts modes only; it must not short-circuit the device's own final
   validation — a lexically-valid but checksum-invalid word set types all the
   way through and lets the on-device model resolve `AllWordsEntered` to
   invalid.
2. Scrolling by clamped endpoints: before a letter tap, if the letter is in
   rows 0–3 scroll fully up, else fully down — a drag long enough to clamp
   erases accumulated error, so letter positions are closed-form at exactly
   two scroll values (0 and max). Drags are real `SlideUp`/`SlideDown`-tagged
   touch sequences through `DeviceInput::swipe`.
3. Tap (down + lift) at the geometry-contract point.
4. Wait for the *observed* entry progress to advance before the next key;
   re-tap on no-progress after a bounded wait (the verified-retry pattern the
   android IME typing already uses); bounded attempts then a diagnostic error.
5. Finish when the screen reports success; if `AllWordsEntered` resolves
   invalid (bad checksum), fail fast with the entered state named — never
   hang.

### 3. `SimObservation`: the committable observation boundary

`SimUi` is a type alias for the production `FrostyUi`, which is deliberately
`!Send` and lives inside `DeviceThread` — so UI observation cannot be "a cache
in SimUi" and no widget/UI value may cross the thread boundary. The boundary
is instead sim-owned thread-safe state, crossing threads the same way
`SharedFramebuffer` already does:

- A `SimObservation` (`Arc<Mutex<…>>` of plain data) carried by the router
  slot and `SimDevice`, published from inside the device thread by a
  **sim-only `UserInteraction` wrapper** around `FrostyUi`. The wrapper
  delegates every call; on the calls that change what's on screen it also
  publishes.
- Published values only, never UI types:
  - `displayed_backup: Option<String>` — extracted (`to_string()`) at publish
    time from a `Workflow::DisplayBackup`; the wrapper does not retain a
    cloned `Workflow` (no second copy of the secret outliving the screen).
  - `entry_progress: Option<EntryProgress>` — a compact plain-data struct
    (row, cursor, mode discriminant, finished/invalid) sampled each `poll()`
    from a read-only accessor on `FrostyUi`'s widget tree (same thread; only
    the extracted plain data is written through the Arc).
- Staleness follows the ACTIVE screen, not workflow configuration:
  `set_default_workflow` only stores the future return destination and does
  not change what is displayed — the wrapper only delegates it. Observations
  are replaced exactly when the active widget changes: on `set_workflow` /
  `go_to_default` the old values are cleared and, for
  `Workflow::DisplayBackup`, the new text is published in the same
  replacement (no observable stale interval); `entry_progress` is refreshed
  after each `poll()`; everything is cleared on device reset / thread
  teardown.

### 4. FRB + harness + docs

- `SimDevice.displayedBackup()` — the full backup text of the display
  workflow currently on screen (privileged sim observation, independent of
  which page is visible); error if the device isn't displaying a backup.
- `SimDevice.typeBackup(text)` — runs the typist to completion; returns on
  the success screen; throws with progress diagnostics on invalid/timeout.
- Dart harness verbs on the device handle; rows in
  `test_driver/COMMANDS.md` and the eval help (tool docs are part of the
  deliverable).

### 4b. The two-call agent surface (scope increase)

Future scenarios drive the whole paper cycle with exactly two calls:

- `AppDevice.recordBackup() -> String` — the whole "write it down" half, a
  BOUNDED, GENERATION-SCOPED state machine (outcome, never screen lifecycle —
  the same rule already enforced for entry):

  1. **Wait for the display.** Poll until the observation publishes a
     displayed backup, capturing `(text, display generation)` under one lock
     (both are published in the same atomic replacement, so a `Some` text
     pins its generation). The wait is bounded by the call's deadline;
     exceeding it is a timeout error naming the state.
  2. **Drive.** Loop page-advance swipe + hold-confirm (widget-owned
     geometry; holds on non-final pages are inert, so no page count is
     assumed). Each round's transition decision reads ONE locked snapshot of
     `(active display generation, displayed?, recorded outcome)` — never
     independently sampled fields, or a `BackupRecorded` landing between an
     outcome read and a screen read would misreport an accepted run as
     canceled. Precedence within the snapshot:
     - the captured generation's recorded outcome → return the captured
       text (success even after the screen has cleared);
     - else the captured generation still the active display → drive
       another round;
     - else → `UnexpectedState`: the display is gone OR another display
       generation replaced it directly (N→N+1 without a `None` in between)
       — cancel, replacement, reset, and power-off are lifecycle, never
       success. Deadline exceeded at any point → timeout error.
  3. **Generation scoping.** `SimObservation` gains a display generation
     (bumped when a display screen becomes active) and a recorded outcome
     keyed to it, recorded from `UiEvent::BackupRecorded` in
     `ObservedUi::poll` (before the loop tears the screen down) and
     surviving clears. An outcome retained from run N never satisfies a call
     that captured run N+1.

- `AppDevice.typeBackup(text)` — the entry half, as already specified.

Committed acceptance for the new model:
- State-machine tests drive `record_on_device` against a synthetically
  published observation (the crate-internal publish side): recorded outcome
  followed by a clear still returns the exact captured text; a clear WITHOUT
  the outcome (cancel/reset/power-off) → `UnexpectedState`, never success;
  replacement by another display generation (no intermediate `None`) →
  `UnexpectedState` immediately; an outcome retained from generation N does
  not satisfy a call that captured generation N+1.
- The e2e's record leg becomes exactly `recordBackup()`, covering the real
  display end to end: the returned text is what `typeBackup` later restores
  to the same address.

The page-level verbs (`backupDisplayNext`/`backupDisplayConfirm`) remain for
fine-grained scenarios. Both calls and their failure behavior documented in
`COMMANDS.md` + eval help.

### 5. Tests

**Widget-level host test** (fast, no device — in `frostsnap_virtual_device`'s
host tests): instantiate `EnterShareScreen` with real constraints, run the
typist's plan through `handle_touch`/`draw` against a scratch target with a
stepped clock; assert `get_backup()` equals the source backup for several
seeded random `ShareBackup`s (exercises Q→U, deep-scroll letters, 1-digit and
multi-digit share indices). Plus: a deliberately wrong word ⇒ entry resolves
invalid and the typist reports it as an error.

**e2e `backup_restore`** (`./fsim test backup_restore`, host + android):

1. Create a 1-of-1 wallet with device 1 (existing keygen driving).
2. App backup flow → device shows `BackupDisplay`, which is PAGED: it opens
   on the key-number page, the words follow across pages, and the
   hold-to-confirm control exists only on the final confirmation page. The
   e2e captures the full text via `displayedBackup()` (privileged
   observation), then drives the real paging — swipes through to the final
   page (page count is deterministic for 25 words; exported as a
   `BackupDisplay` page-geometry helper alongside the keyboard geometry
   contracts) — and hold-confirms there so the device fires
   `BackupRecorded` and the app checklist completes.
3. Delete the wallet from the app (recovery e2e pattern) — the coordinator
   forgets the key.
4. Add a FRESH device 2 (never held a share) and disconnect device 1: the
   captured text is now the only path back.
5. App restore flow → physical-backup route
   (`tell_device_to_enter_physical_backup`) → device 2 shows the entry
   screen → `typeBackup(text)` types all 26 rows → app sees the share,
   restoration completes.
6. Assert wallet identity: same name and same receive address as step 1
   (the recovery e2e's key-identity assertion).

## Acceptance

- The typist enters an arbitrary valid backup end-to-end using only touch
  events; no coordinate constants outside the widgets' own geometry helpers;
  each helper pin-tested against its widget's real `handle_touch`.
- Widget-level round-trip test green for seeded random backups, including a
  scroll-requiring letter and a Q-word; wrong-word case fails cleanly.
- `./fsim test backup_restore` green on host and android; asserts address
  identity after restore-from-typed-backup on a fresh device.
- `COMMANDS.md` + eval help document the two new verbs.
- The observation boundary publishes only plain data (backup text, entry
  progress) through a sim-owned Arc; values are cleared on workflow
  transition / reset / power-off; no UI or widget type crosses the device
  thread.
- `typeBackup` accepts any lexically-valid target (index + 25 BIP39 words)
  and leaves checksum judgment to the on-device model.
- The two-call surface: `recordBackup()` returns the exact displayed text and
  completes only on the device's `BackupRecorded` for the active display
  generation; `recordBackup()` + `typeBackup(text)` are the only mechanical
  calls a scenario needs for the full cycle.

## Risks / notes

- `WordSelector::word_point` mirrors the layout engine's SpaceEvenly math;
  the pin test is what keeps it honest if the layout changes.
- The e2e's typing leg is ~130 closed-loop taps — expect 20–40 s wall clock,
  comparable to the existing recovery e2e (~45 s).
- The `swipe` primitive's gesture tagging must land as
  `handle_vertical_drag` on the entry screen (it already drives tx-review
  swipes through the same `touch_handler` path); verified by the
  scroll-requiring letters in the round-trip test.
