# fsim drive API — the `fsim eval` console

`fsim eval "<dart>"` ships a live Dart snippet to the running daemon (`fsim up`) and evaluates it against the
console scope — the SAME harness the e2e tests drive, so there is no second command vocabulary to drift. A
snippet is a Dart **expression** (its value is printed); you may `await` in it.

The live SESSION state persists across evals — drive actions accumulate (`await session.connect(2)` in one
eval, `session.chain()` reflects it in the next; the app's wallet/chain carry). Each snippet is otherwise a
fresh expression: to thread a VALUE from one eval into another, capture it in the shell and pass it back with
`-a name=value` (see below), or inline it into one expression. For imports, multi-statement bodies, or
top-level type/function declarations, use `fsim test <file>`. `fsim repl` opens this same console interactively
— one line at a time, the session persisting between lines.

This file is the exhaustive reference; `fsim eval --help` prints a cheat-sheet pointing here. It mirrors the
harness API — `AppSession` / `AppDevice` / `AppSemanticsInspector` in `test_driver/sim_harness.dart`,
`SimFaucet` in `lib/sim_faucet.dart` — and `test/console_commands_documented_test.dart` fails if a public
method here goes undocumented.

## Passing values — `-a` / `--arg`

`fsim eval -a name=value [-a n2=v2 …] "<snippet>"` binds each `name` in the snippet's scope to the string
`value`. This is the clean way to reuse a captured value across evals — the shell holds it, no daemon-side var
store:

```
addr=$(fsim eval "await (await session.faucet()).faucetAddress()")              # capture in a shell var
fsim eval -a addr="$addr" "await (await session.faucet()).fund(addr, 100000)"   # pass it into the next eval
```

The value is bound as a `String` (parse it in the snippet if you need a number — `int.parse(n)`) and is never
interpreted as code — `-a 's=a$b'` binds the literal `a$b`. Names must be a plain letter-initial identifier,
not a keyword or a console name (`session`/`instances`/…).

## The console scope

| name | what |
|------|------|
| `session` | the `AppSession` harness — the app + its virtual devices |
| `instances[K]` | the K-th app instance (`fsim up --instances N`); `session` == `instances[0]`. Each `AppSession` (all methods below) on the ONE shared regtest |
| `session.device(n)` | a specific virtual device (1-based; default 1) — raw input + framebuffer |
| `await session.faucet()` | this session's regtest faucet — fund / mine / balances |

## `session` — app, wallet, devices, chain

### App interaction (by semantic label)
| call | returns | does |
|------|---------|------|
| `session.tap(label)` | `void` | tap a widget by its semantic label |
| `session.enterText(label, text)` | `void` | focus a field by label, then type `text`. HOST: needs `fsim up --agent-owns-keyboard` (else the app owns the keyboard for a human). ANDROID: always types through the real on-screen keyboard — the IME visibly opens, existing content is replaced, printable ASCII only (a literal `%s` is rejected) |
| `session.enterFocusedText(text)` | `void` | type into the already-focused field — same keyboard rules as `enterText` |
| `session.keyboardVisible()` | `bool` | is the on-screen keyboard up right now (the app's bottom viewInset > 0)? |
| `session.focusedTextLength()` | `int` | exact untrimmed value length of the focused text field (throws if none) |
| `session.dismissKeyboard()` | `void` | android: hide the on-screen keyboard if it's up (safe — never navigates back); host: no-op |
| `session.adb(args)` | `String` | android-only escape hatch: run `adb -s <this emulator> <args…>`, return stdout (e.g. `session.adb(['shell','input','keyevent','4'])`) |
| `session.exists(label)` | `bool` | is a widget with this label present? |
| `session.getText(label)` | `String` | read a widget's text by its semantic label |
| `session.getTextByKey(key)` | `String` | read a widget's text by its widget key |
| `session.getClipboard()` | `String` | read the app clipboard |
| `session.setClipboard(text)` | `void` | set the app clipboard |
| `session.waitFor(label, {timeout})` | `void` | wait until `label` appears (default 30s) |
| `session.waitForAbsent(label, {timeout})` | `void` | wait until `label` disappears |
| `session.tapUntil(label, expect, {tries, settle})` | `void` | tap `label` until `expect` appears (8 tries) |
| `session.dismissSheetOrDialog()` | `void` | dismiss a bottom sheet / dialog |
| `session.expectAboveBottomInset(label)` | `void` | assert `label` renders above the bottom inset |
| `session.semantics()` | `AppSemanticsInspector` | inspect the current targetable semantic-label surface |

`session.semantics()` accessors fetch a fresh snapshot each call:

| call | returns | does |
|------|---------|------|
| `.labels()` | `List<String>` | unique onstage labels targetable by `tap` / `waitFor` / `exists` |
| `.grep(pattern)` | `List<String>` | targetable labels containing a string or matching a `RegExp` |
| `.pretty()` | `String` | compact human-readable semantics snapshot |
| `.json()` | `String` | structured JSON snapshot with labels plus best-effort metadata |

The stable JSON envelope is `{"nodes":[...]}`. Every currently targetable semantic label appears exactly in
a node's `label` field; `labelFirstSeen` identifies its first occurrence. Other node fields (such as values,
roles, actions, flags, and bounds) are diagnostic and may vary with Flutter.

### Wallet
| call | returns | does |
|------|---------|------|
| `session.createWallet({name, deviceCount, devicePrefix})` | `void` | run the create-multisig-wallet flow |
| `session.deleteWallet()` | `int` | delete the wallet (returns devices affected) |
| `session.openDeviceBackup({device})` | `void` | open the device-backup flow for a device |

### Devices + daisy chain
| call | returns | does |
|------|---------|------|
| `session.deviceNumbers()` | `List<int>` | all device numbers |
| `session.addDevice()` | `int` | add a new virtual device at runtime (returns its number) |
| `session.device(n)` | `AppDevice` | a device handle (see below) |
| `session.chain()` | `List<int>` | connected daisy-chain order |
| `session.setChain(order)` | `void` | re-cable to exactly these devices, in order |
| `session.connect(n)` / `session.plug([n])` | `void` | plug device `n` into the chain tail |
| `session.disconnect(n)` / `session.unplug([n])` | `void` | disconnect `n` + everything downstream |
| `session.moveUp(n)` / `session.moveDown(n)` | `void` | reorder `n` within the chain |

### Diagnostics
| call | returns | does |
|------|---------|------|
| `session.screenshot(name, {keep})` | `String` | capture a whole-app screenshot; returns its path |
| `session.record(path, body, {deviceFile})` | body result | **android only** — record one async body, always stopping + pulling the mp4 to `path` |
| `session.startRecording()` | `void` | **android only** — start recording the emulator screen (native `screenrecord`); call mid-run, then drive |
| `session.stopRecording(path)` | `String` | **android only** — stop the recording + pull its mp4 to `path`; returns `path` (caps at 180s) |
| `session.deleteSecureKey()` | `void` | **android only** (errors on host) — delete the app's StrongBox/TEE `AndroidKeyStore` key; exercises the "key gone → recover" path |
| `session.secureKeyExists()` | `bool` | **android only** (errors on host) — whether the app's secure key exists (verify a `deleteSecureKey`) |

## `session.device(n)` — a virtual device (raw pixel input + framebuffer)

| call | returns | does |
|------|---------|------|
| `.tap(x, y)` | `void` | tap at a pixel |
| `.hold(x, y, duration)` | `void` | press-and-hold at a point |
| `.holdConfirm(x, y, [duration = 2600ms])` | `void` | hold long enough to confirm (device sign/review) |
| `.swipe(x1, y1, x2, y2, duration)` | `void` | swipe between two points |
| `.touch(x, y, {liftUp})` | `void` | a single raw touch-down (`liftUp:false`) or -up (`true`) |
| `.setConnected(connected)` | `void` | plug (`true`) / unplug (`false`) this device |
| `.isConnected()` | `bool` | is this device plugged in? |
| `.deviceId()` | `String` | this device's frost key id |
| `.chain()` | `List<int>` | chain order from this device's view |
| `.setChain(order)` | `void` | re-cable from this device's view |
| `.screen(path)` | `void` | write this device's framebuffer to a PNG |

## `await session.faucet()` — the regtest faucet

| call | returns | does |
|------|---------|------|
| `.fund(address, sats)` | `String` | send `sats` to `address` (mines a block); returns the txid |
| `.mine(blocks)` | `void` | mine `blocks` blocks (confirm pending txs) |
| `.balanceSat()` | `int` | the node wallet's balance |
| `.addressBalanceSat(address)` | `int` | an address's confirmed balance |
| `.blockHeight()` | `int` | current chain height |
| `.faucetAddress()` | `String` | a fresh faucet-owned address |
| `.electrumUrl()` | `String` | the electrs endpoint the app syncs from |
| `.down()` | `void` | shut down this session's regtest backend |
| `.close()` | `void` | close this faucet connection (leaves the backend running) |

## Examples

```
fsim eval "session.chain()"                                     # -> [1, 2, 3]
fsim eval "(await session.deviceNumbers()).length"              # device count
fsim eval "await session.connect(2)"                            # plug device 2 into the chain
fsim eval "await session.setChain([3, 1, 2])"                   # re-cable to this exact order
fsim eval "session.exists('Create a multi-sig wallet')"         # -> true / false
fsim eval "await session.semantics().grep('Generate keys')"     # targetable labels matching text
fsim eval "await session.semantics().pretty()"                  # readable current app surface
fsim eval "(await session.faucet()).blockHeight()"              # current height
fsim eval "await (await session.faucet()).fund(addr, 100000)"   # fund an address, returns txid
fsim eval "await (await session.faucet()).mine(6)"              # mine 6 blocks (confirm txs)
fsim eval "await session.device(1).holdConfirm(200, 600)"       # device 1 hold-to-confirm
fsim eval "await session.screenshot('after-keygen')"            # -> screenshot path
fsim eval "await session.record('demo.mp4', () async { await session.tap('Open simulator'); return 'recorded'; })"
```
