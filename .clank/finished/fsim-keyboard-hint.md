# fsim-keyboard-hint
# fsim-keyboard-hint — a clear error when text entry needs `--agent-owns-keyboard`

An agent driving a `fsim up` session hit this first thing: `session.enterText(...)` (via `fsim eval`) fails
with a cryptic `Uncaught extension error … enter_text: Bad state` and NO hint that the fix is to relaunch with
`--agent-owns-keyboard`.

## Goal + root cause
`enterText`/`enterFocusedText` call flutter_driver's `driver.enterText`, which only works when the app enabled
`enableFlutterDriverExtension(enableTextEntryEmulation: true)` — and that flag IS `agentOwnsKeyboard`
(`sim_app.dart`). `fsim serve/up` DEFAULTS `agentOwnsKeyboard=false` (`fsim.dart:1497`) — intentional, because
`true` blocks the real keyboard so a human can't type in the GUI (`sim_harness.dart:488`). So driving text
entry on a default `fsim up` session throws the raw `Bad state`. `AppSession` doesn't track its keyboard mode,
so the text-entry verbs can't pre-empt the failure with a useful message. Fix: make them do exactly that.

## Task 1 — precondition error naming the flag
- Thread `agentOwnsKeyboard` into `AppSession` as a `final bool` field: add the constructor param and pass it
  at construction in `AppSession.launch` (`sim_harness.dart:520`) — and any other `AppSession(...)` site.
- In `enterText` AND `enterFocusedText`, FIRST (before touching the driver) `throw StateError(...)` when
  `!agentOwnsKeyboard`, with a clear, actionable message naming the flag — e.g. "text entry needs the
  agent-owned keyboard, but this session hands the keyboard to a human; relaunch with
  `fsim up --agent-owns-keyboard` (or pass `--agent-owns-keyboard` to serve/test)". This also gives
  `createWallet` (which types the wallet + device names) the same clear failure instead of `Bad state`.
- Docs: note the requirement on the `enterText`/`enterFocusedText` rows in `test_driver/COMMANDS.md` (and the
  `-a`-adjacent help if it stays concise) so the flag is discoverable BEFORE hitting the error.
- **Acceptance:** `fsim up` (NO flag) + `fsim eval "await session.enterText('Wallet name', 'x')"` → a clear
  error naming `--agent-owns-keyboard` (NOT `Bad state`), daemon still alive; `fsim up --agent-owns-keyboard` +
  the same → types successfully (no error); the message also fires for `enterFocusedText` and for
  `createWallet` on a no-flag session; `dart analyze` + `dart format` clean.

## Notes
- Considered instead FLIPPING the `fsim up` default to `agentOwnsKeyboard=true` (so eval `enterText` works out
  of the box). REJECTED here: `true` BLOCKS the real keyboard (`sim_harness.dart:488`), so it would break the
  human/GUI interaction the default is designed for, and silently change existing behavior. The clear error
  keeps the GUI-friendly default and guides eval users to the one-flag fix. (If we later decide eval-driving is
  the dominant `fsim up` use, flipping the default + adding a `--human-keyboard` opt-out is a separate call.)
