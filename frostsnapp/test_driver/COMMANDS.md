# fsim drive API — the `fsim eval` console

`fsim eval "<dart>"` ships a live Dart snippet to the running daemon (`fsim up`) and evaluates it against the
console scope — the SAME harness the e2e tests drive, so there is no second command vocabulary to drift. A
snippet is a Dart **expression** (its value is printed); you may `await` in it; state persists across calls
(the daemon isolate is long-lived — a stateful console). For multi-statement snippets, imports, or top-level
declarations, use `fsim test <file>` instead. `fsim repl` opens this same console interactively — one line at
a time, state persisting between lines.

This file is the exhaustive reference; `fsim eval --help` prints a cheat-sheet pointing here. It mirrors the
harness API — `AppSession` / `AppDevice` in `test_driver/sim_harness.dart`, `SimFaucet` in `lib/sim_faucet.dart`
— and `test/console_commands_documented_test.dart` fails if a public method here goes undocumented.

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
| `session.enterText(label, text)` | `void` | focus a field by label, then type `text` |
| `session.enterFocusedText(text)` | `void` | type into the already-focused field |
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
fsim eval "(await session.faucet()).blockHeight()"              # current height
fsim eval "await (await session.faucet()).fund(addr, 100000)"   # fund an address, returns txid
fsim eval "await (await session.faucet()).mine(6)"              # mine 6 blocks (confirm txs)
fsim eval "await session.device(1).holdConfirm(200, 600)"       # device 1 hold-to-confirm
fsim eval "await session.screenshot('after-keygen')"            # -> screenshot path
```
