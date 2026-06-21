# sim-11-sim-driving-modes
# sim-11: two explicit sim driving modes (user vs agent)

## Goal
The sim has two distinct ways to be driven and they need different text-input plumbing, so
make them two explicit modes rather than one mode that tries to serve both:
- **User mode** — a human drives the running app with the real keyboard + mouse/trackpad.
- **Agent mode** — automation drives the widget tree out-of-process via `flutter_driver`
  (semantic taps + `driver.enterText`).

## Why (the bug this fixes)
The sim app channel runs through `test_driver/sim_app.dart`, which calls
`enableFlutterDriverExtension()`. That defaults to `enableTextEntryEmulation: true`, which
registers a MOCK text input on the platform text channel. Per Flutter's own docs: with it on,
`driver.enterText` works but **real keyboard input is swallowed** (the app beeps on physical
typing); with it off, the real keyboard works but `driver.enterText` fails. The two are mutually
exclusive — there is no hybrid. Since sim-8 introduced the driver harness, every interactive
`simctl serve` session has had emulation on, so a human could not type (it worked in sim-7, which
ran without the driver — hence "it stopped working").

## Core model (read first)
The mode is named for WHO OWNS THE KEYBOARD — the single switch, surfaced directly rather than as a
flutter_driver internal term:
- **Agent mode** (the agent owns the keyboard): `enableFlutterDriverExtension(enableTextEntryEmulation:
  true)`. The harness's `SimHarness.launch` defaults to this, so `runScenario` tests
  (`keygen_drive`, `multi_device_drive`) keep using `driver.enterText`.
- **User mode** (a human owns the keyboard): `enableFlutterDriverExtension(enableTextEntryEmulation:
  false)`. `simctl serve` defaults to this so a human types normally. The driver extension stays
  enabled, so taps/holds/plug-toggles/screenshots over `simctl` and the device channel still work —
  only `simctl enter` (driver text injection) is unavailable, and it is rejected with a clear,
  mode-specific error (type directly, or relaunch with `--agent-owns-keyboard`).

No hybrid: a session is one mode for its whole life, chosen at launch.

Surface, intent-first:
- CLI: `simctl serve` = user mode; `simctl serve --agent-owns-keyboard` = agent mode.
- Harness: `SimHarness.launch({bool agentOwnsKeyboard = true})`.
- Transport: `--dart-define=SIM_AGENT_OWNS_KEYBOARD=<bool>` -> `enableTextEntryEmulation`.

## Tasks
1. `test_driver/sim_app.dart`: read `SIM_AGENT_OWNS_KEYBOARD` (default true) and pass it to
   `enableFlutterDriverExtension(enableTextEntryEmulation: ...)`.
2. `SimHarness.launch({bool agentOwnsKeyboard = true})`: forward it as
   `--dart-define=SIM_AGENT_OWNS_KEYBOARD=...`. `runScenario` keeps the default (agent mode).
3. `simctl serve`: default to user mode; accept `--agent-owns-keyboard` for agent mode. Reject
   `simctl enter` in user mode with a clear error AND say so in the usage text — the no-hybrid model
   must be visible on the command surface, not just in a source comment.

## Acceptance
- `flutter analyze` + `dart-format-check-app` clean.
- Interactive: `just sim-serve` → typing into a text field with the real keyboard works (verified by
  injecting OS-level keystrokes into the wallet-name field and seeing the text land); `just sim enter`
  in that session is rejected with the clear mode-specific error rather than a generic driver failure.
- Automated: `keygen_drive` / `multi_device_drive` still pass (they use `driver.enterText`, i.e. the
  default agent mode), so the fix doesn't regress the test path.

## Depends on
sim-8 (the driver harness + `simctl`), sim-9/sim-10 (multi-device `SimHarness.launch`).
