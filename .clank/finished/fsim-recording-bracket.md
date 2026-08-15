# fsim-recording-bracket
# fsim recording bracket

## Goal

Make recording one driven span ergonomic and failure-safe inside the existing `fsim eval` surface. The low-level
`startRecording()` / `stopRecording(path)` methods already do the Android recording work; add a small wrapper so
callers do not have to repeat the async IIFE plus `try` / `finally` ceremony:

```sh
./fsim eval 'await session.record("demo.mp4", () async {
  await session.tap("Open simulator");
  await session.waitFor("Close simulator");
})'
```

## Scope

- Add `Future<T> record<T>(String path, Future<T> Function() body, {String deviceFile = ...})` to
  `AppSession`.
- Start recording, run `body`, and always attempt `stopRecording(path)` in `finally`.
- Return the body's value after the recording has finalized and been pulled successfully.
- If the body throws and stopping succeeds, preserve the body's original error and stack trace. If stopping also
  fails, use normal Dart `finally` behavior and surface the stop/finalization failure.
- Reuse `startRecording()` and `stopRecording()` unchanged so Android-only behavior, double-start checks, the
  180-second cap, device-file cleanup, and output validation retain one implementation.
- Keep the helper entirely in the eval/test harness API. Do not add a top-level `fsim record` command.
- Document the helper and a one-eval example in `test_driver/COMMANDS.md`; the existing command documentation
  drift guard should cover the new public `AppSession` method.

## Acceptance

- On an Android session, one `fsim eval` call can record a multi-step async body and returns the body's value;
  the requested host path contains the finalized MP4.
- A body that throws still attempts stop/pull, reports the body error when finalization succeeds, and leaves the
  session able to start another recording.
- Starting or stopping failures remain clear and are not converted into a successful body result.
- Host sessions retain the existing clear Android-only error.
- Focused analysis, formatting, documentation drift tests, and an Android recording smoke check pass.

## Non-goals

- No host/macOS recording support.
- No timed sequence DSL, new eval syntax, or top-level recording command.
- No changes to screenrecord encoding, duration, or process management.
