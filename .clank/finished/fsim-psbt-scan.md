# fsim-psbt-scan
# fsim coverage for the PSBT signing flow

There is no test for PSBT signing anywhere. This is the wallet's interop half — a transaction the
app did **not** build — and it is entirely uncovered.

Milestone 1 (done, this revision) investigated the design space and chose a direction. The
original design-space text is preserved in git history at the plan's intro commit; what follows is
the decision, the argument for it, and the implementation milestones.

## The direction

**bitcoind authors the PSBT; the app scans it as an animated `crypto-psbt` UR through its real
decode pipeline; the sim substitutes only the lens — and before any sim code exists, the
duplicated scan pipeline is collapsed so the lens seam feeds the one copy of the code Android
actually ships.**

Concretely, the e2e: keygen a 2-of-3 sim wallet, export its output descriptor to the regtest
node as a watch-only wallet, fund it with four separate UTXOs, have **bitcoind** build a spend
large enough that coin selection must take all four inputs (pushing the PSBT past one 400-byte UR
fragment, so the QR is genuinely animated), render the UR parts as real QR images, put them in
front of the sim's camera lens, and let the app's real `rqrr` grid detection, UR fountain
assembly, PSBT parse, ownership validation, device signing (a 2-device subset driving the real
review + hold-to-sign screens), broadcast and confirmation all run unmodified. Assert the
destination balance node-side.

## Why this direction

**Axis 1 — substitute at the lens, not deeper and not shallower.** Everything below the frame
callback is ours: `rqrr` grid detection on real image bytes, `ur` fountain assembly,
`trim_until_psbt_magic`, `Psbt::deserialize`, `psbtToUnsignedTx` validation, the signing flow.
Injecting frames of really-rendered QR images keeps every line of that real. Substituting deeper
(decoder or ingest result) would skip the code this plan exists to cover. Substituting shallower —
the emulator's virtualscene camera — is rejected on structural grounds, not on the unproven decode
question:

- the camera *mode* is launch-time, but the harness attaches to already-booted pool slots
  (`bootEmulator`), so the mode cannot be guaranteed per-test without reshaping the emulator pool
  and taxing every slot with virtualscene rendering;
- an animated UR would need wall-poster swaps through the qemu console at scan cadence with no
  synchronization signal — a timing-flake machine by construction;
- even if it ran green, the coverage it adds over lens substitution is CameraX + MLKit — Google's
  code. A regression there is not actionable by us.

Since (a) and (b) alone decline the route, the "does a poster QR survive MLKit + rqrr at all"
experiment isn't needed.

**Axis 2 — make the duplication go away, then there is only one copy to test.**
`MobileCameraWidget` and `NativeCameraWidget` hold near-duplicate scan-result handling and
near-duplicate chrome; they genuinely differ only in the *lens* — CameraX/MLKit-gated
`capture.image` frames plus zoom UI on Android, a `CameraDevice.start()` stream plus device picker
on Linux/Windows. The prior spike injected into `NativeCameraWidget`, testing the copy Android
does not ship. The fix is not to point the sim at the other copy — it is to collapse the pipeline
so "which copy" stops being a question. Milestone 2 extracts the single scan page owning the one
copy of result handling (keeping the mobile variant's `progress != result.progress` guard as the
behavior); lenses become small frame-source + preview implementations. The sim then adds a third
lens, and by construction exercises exactly the result-handling code every platform ships.

**Axis 3 — "Scan" is the right ingest.** The QR path is the flagship air-gapped interop flow
(Sparrow/Core → Frostsnap) and is where all the code we own lives. "Open file" is DocumentsUI — a
system activity outside the Flutter view, driveable only by scripting Google's layout per API
level. A `VIEW`/`SEND` intent filter for `.psbt` files would be a genuine product feature and
deserves its own argued plan, not a side-door existence as test scaffolding.

**Axes 4/5 — bitcoind authors the PSBT, live, no fixture.** The wallet's keys exist only at
runtime, so nothing can be pre-baked; a fixture is impossible, an in-app-built PSBT would prove
almost nothing. A watch-only descriptor wallet on the session's regtest node is the real
Core/Sparrow flow: bitcoind picks the inputs, computes change, sets feerate, and emits the
`witness_utxo` / `tap_internal_key` / origin metadata the app demands. Its coin selection is made
deterministic-enough by construction: the spend amount exceeds any three UTXOs, so all four inputs
must be selected and the multi-part property cannot silently vanish. A unit test in `sim_regtest`
pins the PSBT contract itself (see acceptance), so if Core's output shape drifts the failure names
the contract, not the e2e symptom.

## Deliberately not covered

- **CameraX + MLKit.** The sim lens replaces the whole lens; Google's camera stack never runs
  under sim. Fidelity caveat, stated plainly: in production Android, MLKit gates which frames
  reach `scanFrame`; under sim every scene frame reaches it. The injected frames all contain QR
  codes, so the difference is load-shaping, not logic.
- **The "Open file" ingest and any intent filter** — the former is undriveable Google UI, the
  latter is a product feature to argue separately.
- **Cross-implementation UR interop.** The harness encodes UR parts with the app's own `QrEncoder`
  (the `ur` crate) and renders QR images itself, so the fountain-coding layer is a same-library
  round-trip. The PSBT inside is foreign — that is the interop that matters — but a UR stream
  authored by another wallet's encoder is not covered and cannot be (it would have to be generated
  against runtime keys by a second UR implementation, bought for little).
- **The address scanner** (`MobileQrScanner` / `AddressScanner`) — a genuinely different pipeline
  (MLKit is the *decoder* there, not just the camera); left untouched by the dedup.

## Milestone 2 — collapse the duplicated frame-scan pipeline

One scan page owns the single copy of: frame→`scanFrame` plumbing, the finished-scanning latch,
the error snackbar, the progress card, pop-with-result, the close button. `MobileCameraWidget` and
`NativeCameraWidget` reduce to lenses: a preview widget plus a frame source (Android: the
MLKit-gated `capture.image` bytes and the zoom slider; Linux/Windows: the `CameraDevice` stream
and the device dropdown). Behavior-preserving refactor of `lib/camera/` only; the mobile
`progress != result.progress` setState guard becomes the shared behavior. No sim code in this
milestone.

## Milestone 3 — the sim lens, bitcoind PSBT authorship, and the e2e

- **Sim lens**: a `kSim`-gated scene (`lib/sim_camera.dart`-style: harness sets a list of image
  byte arrays; the lens cycles them like an animated QR held in front of a camera). Selected in
  the one place a lens is chosen. The scene must persist-until-replaced and be clearable, and the
  cycle length must not alias with the scanner's frame-drop stride (the spike proved a loop of
  `4×seq+1` fountain parts; fountain parts past the sequence length decode fine).
- **Harness PSBT authorship**: faucet verbs `watch_descriptor` + `create_psbt` in `sim_regtest`
  control + `lib/sim_faucet.dart` (tray and `./fsim` share one wire implementation). Core rejects
  the app's multipath descriptor; expand into the receive/change pair and import each with its
  `internal` flag. A `wallet-descriptor` driver verb exposes the app wallet's checksummed
  descriptor; a `psbt-qr:<base64>` verb encodes + renders + points the lens (rendering app-side:
  `QrEncoder` over FRB, QR modules drawn at a scale `rqrr` decodes with margin, 4-module quiet
  zone); a clear verb empties the lens. `COMMANDS.md` rows + the documented-methods test for every
  new public harness method.
- **The e2e** (`psbt_sign_drive.dart`): the scenario described under "The direction". Android
  lane: `./fsim test psbt_sign --android --jobs 1`; host lane must also pass — the sim lens is
  platform-independent and no real camera is touched on either.

The prior spike (`/Users/llfourn/src/fswt/fsim-psbt`, `e145b1fe`) is evidence these pieces run
green end-to-end and a reference for the Core gotchas; the implementation is written fresh against
the milestone-2 seam, which the spike did not have.

## Acceptance

- `lib/camera/` contains exactly one implementation of frame-scan result handling; mobile, native
  and sim differ only as lenses. No production behavior change.
- The e2e's PSBT is authored by bitcoind (the app builds no transaction anywhere in the scenario),
  spends all four funded UTXOs, and its UR sequence length is ≥ 2 — asserted, so the animated
  property can't silently degrade to a single static QR.
- The decode path is the real one end-to-end: rendered QR PNG bytes → `rqrr` → fountain assembly →
  magic trim → `Psbt.deserialize` → `psbtToUnsignedTx` — no decoder shortcut anywhere in the sim
  path.
- Two of three devices sign through the real device review + hold-to-sign; the tx is broadcast,
  mined, and the destination balance asserted node-side.
- A `sim_regtest` unit test pins the funded PSBT's contract: `witness_utxo` present,
  `tap_internal_key` present, an origin whose fingerprint is the wallet's bitcoin appkey and whose
  path is the 4-segment form `BitcoinBip32Path::from_u32_slice` accepts.
- Both lanes green: `./fsim test psbt_sign` and `./fsim test psbt_sign --android --jobs 1`.

## Constraints

- **No WHAT comments.** Only WHY, and only when the why isn't obvious. Test: delete the comment —
  if the code still says everything it said, leave it deleted.
- **Prefer no test to a mocked one.** The sim path may substitute the lens and nothing else.
- **No production behaviour change** except the milestone-2 refactor (behavior-preserving). Any
  test-only surface in `lib/` is `kSim`-gated, following `lib/sim_device_tray.dart` /
  `lib/sim_faucet.dart` precedent; faucet commands go in `lib/sim_faucet.dart`.
- Read `frostsnapp/test_driver/COMMANDS.md` and `sim_harness.dart` first; `regtest_send_drive.dart`
  is the closest model for a driver doing a real on-chain send.
- **A red run is a claim you have to substantiate.** Read the `[app]` logs before concluding the
  app is at fault.
- Keep `pubspec.lock` out of commits unless a dependency genuinely changed.
