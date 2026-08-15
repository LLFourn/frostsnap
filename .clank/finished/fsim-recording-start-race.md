# fsim-recording-start-race
# Verify — then fix — the recording bracket's late-capture race

Reported (user-relayed, 2026-08-14): a nudge dialog driven immediately after
`startRecording` returned was missing from the pulled clip. The claimed mechanism:
`startRecording` (sim_harness.dart) returns as soon as `adb shell screenrecord` is
SPAWNED, but the encoder needs ~a second before it captures anything, so anything
shown and dismissed inside that window never reaches the file. The reporter worked
around it with a fixed 2 s settle after start; that workaround is NOT in this tree.

The code is consistent with the claim — `startRecording` does `Process.start` and
returns with no readiness wait — but consistency is not reproduction. Verify first;
fix only what the measurement confirms.

## Milestone 1 — verify and measure

On a live android session, instrument the CURRENT behavior (no harness changes —
a throwaway probe script / eval snippet):

- Spawn `screenrecord` exactly as `startRecording` does and poll the on-device
  file's size (`stat -c %s`) at ~50–100 ms cadence. Record the timeline: file
  creation and first growth. Growth means the muxer flushed encoded frames — a
  conservative "capture is live by now" bound, NOT the moment capture began
  (the encoder may buffer captured frames before the first flush).
- The decisive check is the CLIP: `record()` a bracket whose body immediately
  drives a visible change (e.g. open the drawer), pull it, and inspect the
  early frames. Observable early-frame LOSS — the clip beginning after the
  event, missing the pre-event screen — is what confirms the race.

Outcomes: early-frame loss in the clip confirms the race and triggers
Milestone 2 (with first-growth as a candidate conservative readiness signal).
An immediate event present from the clip's beginning means the report does not
reproduce — stop at documented findings and surface that instead of fixing.

### Findings (2026-08-14, this host — emulator idle-ish, app freshly launched)

- **Flush latency**: spawn → first mp4 bytes was ~300–600 ms across three probe
  runs (603 ms, 340 ms, 293 ms), and the file stays at SIZE 0 until the first
  muxer flush lands as ~3.2 KB — no header at configure time on this device, so
  any nonzero size means encoded frames.
- **Symptom repro attempt**: a `record()` bracket that tapped the nav drawer
  immediately after return (≲100 ms). The pulled clip (30 frames, 0.634 s)
  BEGINS on the pre-tap closed home screen and contains the complete drawer
  animation. Nothing was lost.
- **Interpretation**: capture start ≠ first flush. The encoder consumes frames
  well before the muxer's first write; frames produced inside the flush window
  are buffered, not dropped. The 300–600 ms measurement is therefore only an
  upper bound on capture start, and the frame evidence bounds capture start
  BELOW the tap latency. The reported mechanism as stated — spawn-return
  precedes capture by ~1 s, so immediate events are lost — does NOT reproduce
  on this host.
- **What remains true**: capture start is asynchronous with spawn-return and
  UNBOUNDED. Under heavy host load it could stretch into a real loss window —
  plausibly the reporter's environment — and a growth gate would turn "on video
  after return" from a usually-won race into a guarantee, at the cost of
  delaying every bracket's return by the flush latency (~300–600 ms idle, more
  under load). Whether that hardening is wanted despite non-reproduction is the
  user's call. Per the outcome rule above — no early-frame loss in the clip —
  Milestone 2 is NOT applied on this evidence.

## Milestone 2 — gate on the encoder's own signal (only if M1 confirms)

A fixed settle is calibrated to an idle host: under CI load — exactly when clips
matter — encoder startup can exceed it and the bug silently returns; on fast hosts
it wastes the full sleep every bracket. The measurement in M1 hands us a real
signal instead: the file only grows when encoded frames flush.

- **Pre-start reset**: `startRecording` REMOVES the requested `deviceFile` before
  spawning, failing loudly if the removal fails. Without it the growth gate has a
  bypass: `stopRecording` deliberately preserves state on pull/finalize failures,
  and a later session reuses the default `/sdcard/fsim-rec.mp4` — stale bytes
  from a previous run would satisfy the threshold instantly and recreate the
  exact early-return bug.
- `startRecording` waits, after spawning, for the device file to reach a size
  only frame data can explain (threshold chosen FROM the M1 measurements, e.g.
  ≥ 1 KiB if the pre-frame header measures in tens of bytes), polling ~100 ms,
  with a bounded deadline that fails loudly rather than recording nothing.
  Early recorder exit also fails loudly. BOTH failure paths reap the spawned
  recorder (await its exit), remove the partial device file, and clear the
  in-progress state so a retry can start cleanly.
- **Committed regression seam**: the readiness/cleanup logic is factored into a
  small helper taking injected probes (size reader, recorder-exit future, reap
  action, poll/deadline), and committed Dart unit tests cover: threshold
  crossed → success; recorder exits first → clear failure; deadline → clear
  failure; both failure paths invoked the reap, removed the partial file, and
  left state clear for a retry. These tests run with no adb/emulator.
- Contract documented on `startRecording`/`record`: anything driven after return
  is on the video.
- Acceptance: the committed unit tests green; then re-run the M1 instrument
  against the fixed harness — the same immediate-event bracket now shows the
  event in the pulled clip, and the measured return time tracks first-growth
  (no fixed sleep). Clip artifacts kept under the session dir corroborate; they
  are evidence for the android half, not the only regression seam.
- Out of scope: the failure-rerun `AndroidSegmentRecorder` (diagnostic_rerun.dart)
  — it records whole reruns from before app launch, so sub-second start lag is
  immaterial there; its early-exit retry loop already handles recorder startup
  failure differently.

## Constraints

- Android-only surface; no sim/device code changes — this is harness-only.
- No WHAT comments; the gate's doc states the signal and why a sleep is wrong.
- `dart analyze` + `dart format` clean; keep `pubspec.lock` out of commits; reap
  the emulator after validation runs.
