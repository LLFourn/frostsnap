# fsim-android-ime-text

On android, ALL harness text input goes through the real on-screen keyboard: focusing a field pops the IME,
keystrokes arrive through the platform channel, and recordings show what interacting actually looks like.
The driver's mock text input becomes host-only. `enterText`/`enterFocusedText` keep their signatures and
just work on android — the `agentOwnsKeyboard` mutual exclusion no longer applies there.

## Why

`agentOwnsKeyboard` makes agent typing and keyboard visibility mutually exclusive: `sim_app.dart:350-366`
enables `enableTextEntryEmulation` (which blocks the real IME), and without it the text verbs throw
`AgentKeyboardRequired` (`sim_harness.dart:1416-1426`). That's exactly backwards for android — tests assert
a UI state no real user ever sees (text appearing with no keyboard, no viewport resize), and recordings
can't show the one thing they usually exist to show. `adb shell input text`/`keyevent` injects keystrokes
at the OS level, needing no driver mock, so the real IME stays up while the harness types.

Deliberately OUT of scope (revisit if it bites):
- obscured-tap strictness — driver taps inject straight into the Flutter engine and can still hit widgets
  visually under the keyboard; accepted for now.
- per-key soft-key press animation — injection is hardware-style; the keyboard is visible and the layout
  reacts, but its keys don't light up.
- non-ASCII input — `input text` can't inject unicode; fail loudly.

## Scope

### Launch seam — android forces user-keyboard mode
- `AppSession.launch` / `provisionAppInstance` (`sim_harness.dart:310-383,589-625`): android targets force
  `agentOwnsKeyboard: false` (real IME) regardless of the parameter — ONE enforcement point at the seam.
  Host launches unchanged.
- fsim CLI: `--agent-owns-keyboard` combined with `--android` → parse-time reject with a clear message
  (android always types via the on-screen keyboard); help text says so.
- `sim_app.dart` heartbeat (`:367-383`) stays keyed off `agentOwnsKeyboard` — it's a macOS-occlusion
  workaround; the emulator paints continuously (today's `fsim up --android` already runs without it).
- The prebuilt test APK (`ensureAndroidSimApkBuilt`) bakes `SIM_AGENT_OWNS_KEYBOARD=false` at BUILD time —
  the emulator app can't read the host env, so the seam's runtime force never reaches it; the old baked
  `true` re-enabled the mock, which silently swallowed every `TextInput.show` (zero `showSoftInput` calls
  in logcat; all 7 android tests failed "keyboard never appeared" until this flipped).

### Text preflight — pure, validated BEFORE any UI mutation (new `test_driver/ime_text.dart`)
The payload transits TWO parsers: the device shell (adb joins args and the device `sh` tokenizes), and
`input text`'s own decoder (it rewrites the literal sequence `%s` to a space). Validation + encoding are a
pure preflight computed before the harness touches the app — a rejected payload must leave the field (and
focus) untouched.
- `imeTextPreflightError(String text) -> String?`: null iff typeable — every char printable ASCII
  (0x20–0x7E) and no literal `%s` substring (unpreservable: the device decoder would turn it into a
  space). Error names the offending character + index (or the `%s`). Empty text is VALID = clear-only.
- `encodeImeText(String text) -> String`: space → `%s`, then single-quote for the device shell
  (embedded `'` → `'\''`) — the exact argument for `adb shell input text <arg>`. Quotes, `$`, backticks,
  backslashes and other metacharacters ride inside the single quotes untouched; a lone `%` is fine (only
  `%s` is special, and space→`%s` encoding composes with it — covered by the round-trip tests).

### Harness text verbs — IME-backed on android (`sim_harness.dart`)
- `enterText(label, text)` (`:1428`): on android — PREFLIGHT (throw on error, nothing touched yet), then
  semantic tap on the field (existing), wait for the IME-visible gate, clear the field, then — if the
  text is non-empty — `adb -s <serial> shell input text <encoded>`. Host path unchanged.
- Clear (REPLACE semantics parity with the mock path): move-to-end (`KEYCODE_MOVE_END`) + counted
  backspaces, count = the focused text field's semantics value length (+ slack for the trimmed edges;
  extra backspaces past empty are no-ops), batched in one `input keyevent` call. NOT select-all: a
  Ctrl+A chord via `input keycombination` (numeric or named codes) never reaches the Flutter field
  (verified live on the emulator), and a focus tap can land the cursor mid-value — the end-anchor makes
  the counted clear correct regardless.
- `enterFocusedText(text)` (`:1435`): same minus the tap.
- IME-visible gate: app-side signal, not android internals — ADD a `keyboard-visible` case to the
  `sim_app.dart` `_driverData` handler returning whether the app's bottom viewInset > 0 (what the app
  itself sees). Nudge-then-poll, bounded (~30s): each ~2s the harness re-requests the IME via an
  app-side `show-keyboard` case (`TextInput.show`) — right after a cold boot the IME service can drop
  the focus-fired show and Android never retries it. Timeout → clear error.
- `_requireAgentKeyboard` (`:1418`) guards only the host mock path now; message updated.

### Tests — `frostsnapp/test/ime_text_test.dart` (pure preflight)
- Rejection: a non-ASCII char (é / emoji) and a control char → error naming char + index; literal `%s`
  → error; all WITHOUT any encoding output (rejection precedes side effects by construction — the
  harness only taps after a null preflight error).
- Encoding round-trip: applying the device's decode (`replaceAll('%s', ' ')`) to the pre-quote encoding
  reproduces the original for: spaces (single/multiple/leading/trailing), lone `%`, `%` adjacent to
  spaces, single + double quotes, `$`/backtick/backslash/`;`/`|`/`*`/`~`, and a bech32 address.
- Shell quoting: embedded `'` produces the `'\''` dance; the result is ONE shell word.
- Empty text → valid, clear-only (no `input text` argument produced).

### New session verbs (`sim_harness.dart`, eval-reachable)
- `session.dismissKeyboard()`: android — if the IME-visible gate says shown, `input keyevent` BACK; if
  already hidden, do NOTHING (an ungated BACK would pop a route). Host: no-op (no on-screen keyboard).
- `session.adb(List<String> args)`: passthrough running `$SDK/platform-tools/adb -s <serial> <args...>`,
  returns stdout, throws with stderr on nonzero. Clear error on host sessions. Serial resolution:
  `_emulatorSerial ?? flutterDevice` (direct android launches pass the serial as `flutterDevice`).
- `test_driver/COMMANDS.md`: document the android text behavior + both verbs.

### Fallout
- Run `fsim test --android`; fix breakages: insert `dismissKeyboard()` where the now-present IME eats a
  subsequent step, adjust waits. Anything that looks like a REAL app bug (field not scrolled into view,
  layout overflow under the shrunk viewport) gets reported, not papered over.

## Acceptance

- `fsim up --android` + eval `session.enterText('Wallet name', 'demo')` → the real keyboard visibly opens
  on the emulator and the text lands (recording/screenshot shows the IME on screen).
- `enterText` into a PREFILLED field replaces the contents (parity with the mock path).
- Non-ASCII text (and literal `%s`) → clear error, field AND focus untouched (preflight rejects before
  any tap/clear).
- A metacharacter-heavy string (quotes, `$`, spaces, lone `%`) survives verbatim — `getText` reads back
  exactly what was sent.
- `enterText(label, '')` clears a prefilled field and types nothing.
- `session.dismissKeyboard()` hides the IME; calling it again does not navigate back.
- `session.adb(['shell', 'echo', 'hi'])` → `hi`; on a host session → clear error.
- `fsim test --android` green after fallout fixes; host suite (`fsim test`) untouched by the diff's host
  paths — mock behavior and `AgentKeyboardRequired` semantics unchanged there.
- `fsim test --android --agent-owns-keyboard` → exit 2 with the android-types-via-IME message.
