# fsim-screen-recording
# fsim-screen-recording — driveable video capture of an android sim session

`session.screenshot()` grabs one app-side PNG; add the moving-picture equivalent for android: start/stop a
NATIVE emulator screen recording MID-RUN via eval, so you record a flow AS you drive it — no frame-sequence
hackery, no perf hit (the recording runs ON the emulator, independent of eval driving).

Mechanism (PROVEN on this box's emulator before writing this plan): `adb -s <serial> shell screenrecord
<devfile>` started detached; `adb -s <serial> shell pkill -INT screenrecord` to finalize the mp4 (SIGINT is
what flushes it); `adb -s <serial> pull <devfile> <host>`. That yielded a valid MP4 (ISO Media, h264, 12.7s).

## Goal
Two driveable `AppSession` methods, used via `fsim eval` like any other command, started/stopped at any point:
```
fsim eval "await session.startRecording()"                 # after setup, mid-run
fsim eval "await session.tap('Open simulator')"            # …drive a flow with visible motion…
fsim eval "await session.stopRecording('demo.mp4')"        # → a real h264 mp4 of the flow
```
Per-`AppSession` (per emulator), so `instances[K].startRecording()` records that instance independently.

## Task 1 — `session.startRecording()` / `session.stopRecording(path)`
- `Future<void> startRecording({String deviceFile = '/sdcard/fsim-rec.mp4'})`:
  - ANDROID-ONLY: require `_emulatorSerial != null`, else a CLEAR error (`recording needs an android session
    (emulator screenrecord); this is a host session`). Host video (ffmpeg avfoundation) is a separate path,
    out of scope.
  - Reject a double start (a recording already in progress) with a clear error.
  - `Process.start(adb, ['-s', serial, 'shell', 'screenrecord', deviceFile])` DETACHED (do not await;
    wireProcessLogs best-effort). Track it: `_recording = (proc, deviceFile)`.
- `Future<String> stopRecording(String path)`:
  - Require an in-progress recording (else clear error `no recording in progress`).
  - `adb -s serial shell pkill -INT screenrecord` (finalizes the mp4); `await proc.exitCode` (bounded, e.g. 10s)
    so the flush completes; `adb -s serial pull deviceFile path`; `rm -f` the on-device file; clear `_recording`;
    return `path`.
- Keep `pkill` per-serial (each `AppSession` == one emulator; a multi-instance `up` records each independently).
- Docs: add both rows to `test_driver/COMMANDS.md` (a "Recording" note under `session`) so the drift-guard test
  (`console_commands_documented_test`) passes; note android-only + the 180s cap.
- **Acceptance (validated on android on this box):** `fsim up --android` → `fsim eval "await
  session.startRecording()"` (no error) → drive a flow with VISIBLE motion (open the tray, connect/disconnect a
  device) → `fsim eval "await session.stopRecording('/tmp/demo.mp4')"` returns the path and the file is a valid
  MP4 with a video stream and duration > 0 (`ffprobe`); the clip SHOWS the driven motion. `startRecording()` on
  a HOST `fsim up` → clear android-only error, daemon alive. `stopRecording()` with no active recording, and a
  double `startRecording()`, each error clearly. `dart analyze` + `dart format` clean.

## Notes
- ANDROID-ONLY (native emulator `screenrecord`). A host (macOS) recorder would be `ffmpeg -f avfoundation`
  window capture — a separate, fiddlier path, deliberately out of scope here.
- `screenrecord`'s 180s cap per invocation stands (fine per the user — no segment-chaining). If a drive runs
  past 180s the mp4 finalizes at 180s; `stopRecording` still pulls it.
- A recording NOT stopped before `down`/`clean` is LOST — the emulator (and its `/sdcard` file) is reaped.
  Stop + pull first. (tearDown may best-effort `pkill` a dangling recording, but the emulator kill reaps it
  regardless.)
