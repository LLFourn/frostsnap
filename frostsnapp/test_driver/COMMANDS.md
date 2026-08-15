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
| `session.tapWithin(ancestorKey, label)` | `void` | tap the one widget matching `label` INSIDE the widget with `ValueKey(ancestorKey)` — scopes a label that is ambiguous only because the screen holds several regions (e.g. a dialog's own "Close" action vs the chrome's header X) |
| `session.tapTooltip(t)` | `void` | tap a tooltip-only control (String or RegExp, resolved to exactly one on-stage tooltip; zero/many list the candidates) |
| `session.tapAppAt(x, y)` | `void` | tap the app at global LOGICAL coordinates (positional escape hatch; same space as the snapshot's global bounds) |
| `session.enterText(label, text)` | `void` | focus a field by label, then type `text`. HOST: needs `fsim up --agent-owns-keyboard` (else the app owns the keyboard for a human). ANDROID: always types through the real on-screen keyboard — the IME visibly opens, existing content is replaced, printable ASCII only (a literal `%s` is rejected) |
| `session.enterFocusedText(text)` | `void` | type into the already-focused field — same keyboard rules as `enterText` |
| `session.keyboardVisible()` | `bool` | is the on-screen keyboard up right now (the app's bottom viewInset > 0)? |
| `session.focusedTextLength()` | `int` | exact untrimmed value length of the focused text field (throws if none) |
| `session.dismissKeyboard()` | `void` | android: hide the on-screen keyboard if it's up (safe — never navigates back); host: no-op |
| `session.stallApp(duration)` | `void` | SIM-ONLY: block the app's UI isolate for `duration`. The only way to make "the app stopped answering" happen deliberately — a driver action issued during it reports contention rather than anything about its target. Do NOT await it if you want to act during the stall |
| `session.tapWhenUnique(label, {timeout})` | `void` | tap [label] once it names exactly ONE reachable control — for a target that is briefly duplicated (two sheets stacked while one closes). Retries the ACTION, never a count read, and acts at most once; a timed-out attempt is never retried |
| `session.showDuplicateTargets(label, count, {settleAfter})` | `void` | SIM-ONLY fixture: put `count` controls carrying the SAME label on screen (settling to one after `settleAfter`), so "two identical hit-testable targets" is deterministic. Returns once they are actually reachable |
| `session.duplicateTargetTaps()` | `int` | activations of the duplicate-target fixture since it was shown — lets a test assert an action fired EXACTLY once |
| `session.blockDuplicateTargetTap(duration)` | `void` | SIM-ONLY fixture: make a tap on the duplicate targets RECORD itself and then block the UI isolate for `duration` — the only way to time out an ACTION that was genuinely dispatched, rather than a phase before it |
| `session.provokeBuildError()` | `void` | SIM-ONLY: throw inside `build` — the RED SCREEN case. Forces the frame before returning, so the error is recorded (and attributed) before the call completes |
| `session.provokeFrameworkError()` | `void` | SIM-ONLY: report a framework error that renders nothing, reaching `FlutterError.onError` alone |
| `session.provokeAsyncError({after})` | `void` | SIM-ONLY: throw asynchronously, escaping the zone. `after` delays it, so it can be timed to arrive past a command's own drain |
| `session.armTappableBuildError()` | `void` | SIM-ONLY: show a control that destroys itself when tapped — the tap arms a build failure and the control is inside the subtree that throws, so its label disappears |
| `session.clearProvokedError()` | `void` | SIM-ONLY: stop the build failure, restoring the wrecked subtree |
| `session.expectAppErrors(pattern, body)` | `T` | run `body` ALLOWING Flutter errors matching `pattern`; non-matching errors still fail, and a scope that matches nothing fails as stale |
| `session.blockNextDataRequest(duration)` | `void` | SIM-ONLY fixture: make the NEXT app-channel request block for `duration`, putting a diagnostic probe in front of an app that will not answer |
| `session.clearDuplicateTargets()` | `void` | remove the duplicate-target fixture |
| `session.animateApp(duration)` | `void` | SIM-ONLY: keep the app animating (frames scheduled) for `duration` while it stays responsive — a wallet-confetti stand-in with a duration a test can rely on. Any driver command that runs with frame sync ON blocks for as long as it lasts; one that correctly disabled it is unaffected |
| `session.adb(args)` | `String` | android-only escape hatch: run `adb -s <this emulator> <args…>`, return stdout (e.g. `session.adb(['shell','input','keyevent','4'])`) |
| `session.hitTestableCount(label)` | `int` | how many instances of `label` a tap could actually REACH right now, counted the way the driver's finder counts (no dedup). 0 or >1 is exactly when a singular action cannot proceed |
| `session.exists(label)` | `bool` | is a widget with this label present? |
| `session.getText(label)` | `String` | read a widget's text by its semantic label |
| `session.getTextByKey(key)` | `String` | read a widget's text by its widget key |
| `session.getClipboard()` | `String` | read the app clipboard |
| `session.setClipboard(text)` | `void` | set the app clipboard |
| `session.walletDescriptor()` | `String` | the wallet's checksummed output descriptor — feed it to `faucet.watchDescriptor` |
| `session.showPsbtQr(psbt)` | `int` | put a base64 PSBT in front of the sim camera as the animated `crypto-psbt` QR another wallet would display; returns the QR part count |
| `session.hideQr()` | `void` | empty the sim camera's view (so a later scan can't re-decode the last one) |
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
a node's `label` field; `labelFirstSeen` identifies its first occurrence. A node's `tooltip` is targetable
via `tapTooltip`, and `bounds` is the node's GLOBAL rect in the same logical coordinates `tapAppAt(x, y)`
takes — so `bounds` center → `tapAppAt` drives any node positionally. Other node fields (values, roles,
actions, flags, the local `rect`) are diagnostic and may vary with Flutter.

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
| `session.addDevice()` | `int` | add a new factory-fresh virtual device at runtime (returns its number) |
| `session.removeDevice(n)` | `void` | remove device `n` (disconnects it first, daisy-chain semantics); its number is tombstoned — never reused — and later operations on it error |
| `session.saveDeviceState(n)` | `String` | device `n`'s durable state (seed + firmware digest + flash) as opaque base64 — requires the device disconnected; the device stays in the fleet |
| `session.addDeviceFromSavedState(state)` | `int` | restore a saved device as a NEW fleet member (fresh number, same identity, shares intact) plugged into the tail; rejects a saved state whose identity is already live |
| `session.restartApp()` | `void` | kill + relaunch the app IN PLACE (same db) — proves restore-from-db; the app comes back with ZERO devices (re-add from saved states) and the next add gets EXACTLY the number the old generation promised. The whole span is one transaction: overlapping restarts are rejected, a failure anywhere in it is terminal, and only an unexpected app death (or that terminal failure) tears the daemon down |
| `session.staleDeviceHandleProbe(n)` | `String` | test support: removes device `n` and drives a CACHED in-app handle through every stateful method, returning one `op: error` line per probe (pins stale-handle behavior) |
| `session.device(n)` | `AppDevice` | a device handle (see below) |
| `session.chain()` | `List<int>` | connected daisy-chain order |
| `session.setChain(order)` | `void` | re-cable to exactly these devices, in order (throws on a `0`, unknown, removed, or duplicate number) |
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

Turning those mp4s into the GIFs a PR carries — conversion, captions, hosting — is
[RECORDINGS.md](RECORDINGS.md).

## `session.device(n)` — a virtual device (raw pixel input + framebuffer)

| call | returns | does |
|------|---------|------|
| `.tap(x, y)` | `void` | tap at a pixel |
| `.hold(x, y, duration)` | `void` | press-and-hold at a point |
| `.holdConfirm(x, y, [duration = 2600ms])` | `void` | hold long enough to confirm (device sign/review) |
| `.swipe(x1, y1, x2, y2, duration)` | `void` | swipe between two points |
| `.touch(x, y, {liftUp})` | `void` | a single raw touch-down (`liftUp:false`) or -up (`true`) |
| `.recordBackup()` | `String` | the whole "write it down" half: waits for the backup display, captures its full text, drives the paged display (widget-owned geometry) until the device's own `BackupRecorded` fires for this run; returns the text. Cancel/reset/power-off/replacement before the confirm throws — lifecycle is never success — as does the deadline (~3 min). Pairs with `.typeBackup(text)` for the full paper cycle |
| `.displayedBackup()` | `String` | the FULL text (`#N WORD1 … WORD25`) of the backup being displayed — privileged sim observation, page-independent; throws if no backup is on screen |
| `.backupDisplayNext()` | `void` | advance the paged backup display one page (swipe span owned by the display widget) |
| `.backupDisplayConfirm()` | `void` | hold the display's confirmation control to confirm ("I've recorded it"); point probed from the page's own hit-testing (~2.6 s) |
| `.typeBackup(text)` | `void` | type a whole backup (`#N` + 25 BIP39 words, case-insensitive) on the entry screen as real touches; the device judges the checksum (invalid sets type through and throw); ~a minute |
| `.setConnected(connected)` | `void` | plug (`true`) / unplug (`false`) this device (throws once the device is removed) |
| `.setFirmwareDigest(hex)` | `void` | set the firmware digest this device claims (64 hex chars), any time; the next announce reports it — an unrecognized digest makes the app offer the firmware upgrade |
| `.isConnected()` | `bool` | is this device plugged in? |
| `.deviceId()` | `String` | this device's frost key id — stable across connect/disconnect and a saved-state restore, NEW after an erase (which wipes the flash header it derives from) |
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
| `.watchDescriptor(descriptor)` | `void` | track an app wallet's descriptor in a node-side watch-only wallet (rescans) |
| `.rpc(method, [params])` | `Object?` | raw bitcoind JSON-RPC passthrough — the escape hatch: compose one-off chain/descriptor questions in the test file instead of adding a control verb (recipe below) |
| `.createPsbt(address, sats)` | `String` | a base64 PSBT paying `sats` to `address`, funded by bitcoind out of the watched wallet's coins |
| `.down()` | `void` | shut down this session's regtest backend |
| `.close()` | `void` | close this faucet connection (leaves the backend running) |

### Recipe: derive the app wallet's addresses independently (via `.rpc`)

Which address does keychain `K` (0 = receive, 1 = change) hold at index `I`? Derive it
OUTSIDE the app — from the app's own exported descriptor, using only bitcoind — so an
assertion about where an output landed can't inherit an app-side derivation bug:

```dart
const keychain = 1; // 0 = receive, 1 = change
const index = 0;
final faucet = await session.faucet();
final descriptor = await session.walletDescriptor();     // multipath: ...<0;1>...#checksum
final single = descriptor.replaceAll('<0;1>', '$keychain').split('#').first;
final info = await faucet.rpc('getdescriptorinfo', [single]);
final canonical = (info as Map)['descriptor'] as String;  // re-checksummed
final addrs = await faucet.rpc('deriveaddresses', [canonical, [index, index]]);
final address = (addrs as List).single as String;
```

The same shape answers other one-off questions (`decodepsbt`, `getrawtransaction`,
`scantxoutset`, …) — compose in the test file; don't add control verbs.

## Examples

```
fsim eval "session.chain()"                                     # -> [1, 2, 3]
fsim eval "(await session.deviceNumbers()).length"              # device count
fsim eval "await session.connect(2)"                            # plug device 2 into the chain
fsim eval "await session.setChain([3, 1, 2])"                   # re-cable to this exact order
fsim eval "session.exists('Create a multi-sig wallet')"         # -> true / false
fsim eval "await session.semantics().grep('Generate keys')"     # targetable labels matching text
fsim eval "await session.semantics().pretty()"                  # readable current app surface
fsim eval "await session.tapTooltip('Copy node address')"       # tap a tooltip-only control
fsim eval "await session.tapAppAt(640, 42)"                     # positional tap (logical px)
fsim eval "(await session.faucet()).blockHeight()"              # current height
fsim eval "await (await session.faucet()).fund(addr, 100000)"   # fund an address, returns txid
fsim eval "await (await session.faucet()).mine(6)"              # mine 6 blocks (confirm txs)
fsim eval "await session.device(1).holdConfirm(200, 600)"       # device 1 hold-to-confirm
fsim eval "await session.screenshot('after-keygen')"            # -> screenshot path
fsim eval "await session.record('demo.mp4', () async { await session.tap('Open simulator'); return 'recorded'; })"
```

## Writing a test that is expected to fail

A test whose subject is a KNOWN bug can be committed red, so the fix flips it green on its own.
Declare the expectation around the one assertion that documents the bug:

```dart
// One object, declared at file scope so the runner and the guard share it.
final _changeOnFirstAddress = ExpectedFailure(
  "the first send's change must use the first change address (internal index 0)",
  fixedBy: 'f15560fe',                       // the commit that should retire this
);

await SimHarness.runScenario('regtest_change_first', (h) async {
  // …everything up to the subject is UNGUARDED: launch, keygen, funding, UI, signing…

  // Observation is also unguarded — a broken backend is not a known defect.
  final landedAt0 = await faucet.addressBalanceSat(expectedChange);

  // Only the throw that documents the defect is guarded.
  final hit = await _changeOnFirstAddress.guard(() async {
    if (landedAt0 == 0) throw StateError('…landed at internal index 2…');
  });
  // Checks that only make sense once the defect is gone. `return`, never throw: the
  // scenario's `finally` and the Scenario teardown still run.
  if (hit) return;

  if (landedAt0 != expectedAmount) throw StateError('…');   // independent claim, unguarded
}, expectedToFail: _changeOnFirstAddress);                  // declared BEFORE any setup
```

Passing the object to `runScenario` is what emits the declaration before setup, which is how a
scenario that dies during launch — or returns before reaching its guard — is caught as a stale
expectation instead of a pass.

The expectation covers THAT ASSERTION and nothing else — everything before and after it fails the
run normally, so a startup crash, a flaky tap, or a backend outage in the same scenario is still a
plain `FAILED`. The runner reports:

| what happened | verdict | fails the run? |
|---|---|---|
| the designated assertion failed | `xfail` | no |
| the designated assertion PASSED | `XPASS` | **yes** |
| the run ended without reaching it | `XPASS` | **yes** |
| anything else failed | `FAILED` | yes |
| the run wedged | `TIMEOUT` | yes |

`XPASS` failing is the point: the only way an expected-fail test breaks the build is by being
fixed. **When that happens, retire the expectation in the same change** — delete the
`ExpectedFailure` object and the `expectedToFail:` argument, drop the `guard` wrapper and the
`if (hit) return;`, and leave the assertion inline so it guards the fix from then on. Leaving any
of it in place is how a suite starts lying about what it covers.
