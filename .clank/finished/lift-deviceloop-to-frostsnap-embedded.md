# lift-deviceloop-to-frostsnap-embedded
# Lift `DeviceLoop` into `frostsnap_embedded` behind a minimal `DeviceHal`

Move the hardware-agnostic device firmware (run loop + UI) out of the esp32
`device` crate into `frostsnap_embedded`, so it compiles and runs on a dev
machine, with `device/` reduced to the esp-hal implementation. Separate PR — no
transport / Flutter / sim work here. **Design goal: smallest honest trait surface
— reuse standard + existing traits; the only device-specific concerns (secrets,
firmware/attestation) get one seam each, kept *out* of the portable core.**

## Problem

`DeviceLoop` (`device/src/esp32_run.rs:58`) is the firmware run loop, already
mostly hardware-agnostic, but it owns esp-hal types and esp-specific crypto. The
two hard, intertwined boundaries (confirmed by code audit):

- **Secret derivation is a `&mut` object, not bytes.** Core consumes
  `frostsnap_core::DeviceSecretDerivation` (`frostsnap_core/src/device.rs:906` —
  `get_share_encryption_key`, `derive_nonce_seed`, both `&mut self`). `EfuseHmacKey`
  (`device/src/efuse.rs:460`, holds `Rc<RefCell<esp_hal::hmac::Hmac>>`) implements
  it and is passed `&mut` into the signer at `esp32_run.rs:596,659,684,697,722,731`
  (`do_work` / `decrypt_to_backup` / `finish_consolidation` / `keygen_ack` /
  `sign_ack`). A *second* key derives the device keypair:
  `FlashHeader::device_keypair(&mut EfuseHmacKey)` (`device/src/flash/header.rs:22`)
  via `hash("frostsnap-device-keypair", seed)`.
- **OTA / firmware / genuine live inside the loop.** `DeviceLoop` holds
  `ota_partitions`, `sha256: &mut Sha`, `rsa: &mut Rsa`, `hardware_rsa: Option<HardwareDs>`,
  `active_firmware_digest`, `upgrade: Option<FirmwareUpgradeMode>`
  (`esp32_run.rs:62–90`); handles `CoordinatorSendBody::Upgrade` via
  `ota_partitions.start_upgrade` (`:534–558`), drives `upgrade.poll` /
  `enter_upgrade_mode` (`:467–494`, takes serial+sha+timer+rsa), computes
  `active_firmware_digest` from hardware SHA over the active partition (`:165`)
  for `Announce` (`:356`), and signs the genuine `Challenge` with `HardwareDs`
  (`:562–574`, `ds.rs:23`).

`frostsnap_embedded` is `#![no_std]` + a `std` feature, esp-free, and consumed
only by `device` — the natural home.

## Design

### Trait surface — reuse first, then two small seams

**Reused (no new surface):**
- `frostsnap_core::DeviceSecretDerivation` — the share-encryption secret object (already the bound the signer takes).
- `embedded_graphics::DrawTarget<Color = Rgb565>` (display), `embedded_storage::nor_flash::{NorFlash, ReadNorFlash}` (flash), `rand_core::{RngCore, CryptoRng}` (rng).
- `embedded_io::{Read, Write, ReadReady}` — serial byte transport (`ReadReady` = the non-blocking poll the loop needs).
- `bincode::{enc::write::Writer, de::read::Reader}` — the framing already implements these (`device/src/io.rs:175`); they stay, over a thin adapter (below).

**New seam 1 — `DeviceHal`** (the peripheral bundle):

```rust
pub trait DeviceHal {
    type Storage:    NorFlash + ReadNorFlash;                 // backing flash (RefCell-shared)
    type Upstream:   embedded_io::Read + embedded_io::Write + embedded_io::ReadReady; // to coordinator/parent
    type Downstream: embedded_io::Read + embedded_io::Write + embedded_io::ReadReady; // to child device
    type Rng:        RngCore + CryptoRng;
    type Secrets:    frostsnap_core::DeviceSecretDerivation;  // the share-encryption key object
    type Firmware:   FirmwareServices;                        // seam 2

    // NB: no `nvs(&self)` accessor — the NVS partition is passed into
    // `DeviceLoop::new` separately (see storage note); an `&self` accessor would
    // be self-referential once the loop owns both `hal` and the split handles.
    /// One split-borrow so the loop can hold &mut to several parts at once
    /// (today they are separate struct fields; a bundle needs this to avoid
    /// aliasing &mut self). Returns a struct of independent &mut sub-borrows.
    fn parts(&mut self) -> HalParts<'_, Self>;

    fn now_ms(&self) -> u64;                                  // monotonic clock
    fn next_touch(&mut self) -> Option<TouchEvent>;          // pull model (esp `TouchReceiver` shape)
    fn downstream_present(&self) -> bool;                     // the GPIO downstream-detect
    fn device_keypair_seed(&mut self, seed: &[u8; 32]) -> [u8; 32]; // fixed-entropy keyed hash -> KeyPair built in-core
}
```

**Ownership model (one, explicit): the display is NOT on `DeviceHal`.** It lives
inside the `UserInteraction` object (`FrostyUi<D>` owns its `D: DrawTarget`, per
the UI/touch split). `DeviceLoop<H: DeviceHal, U: UserInteraction>` holds the HAL
and the UI as separate things; the platform constructs the UI (esp:
`FrostyUi<EspDisplay>`; host: `FrostyUi<OffscreenDisplay>`) and passes it to
`DeviceLoop::new(hal, ui)`. The loop drives `ui.poll(hal.now_ms(),
hal.next_touch())`. Dropping `type Display`/`&mut Display` keeps the HAL surface
smaller (the stated goal) and avoids the display-ownership ambiguity.

`HalParts<'a, H>` carries `&mut Upstream/Downstream/Rng/Secrets/Firmware` (no
display, **no flash** — see storage below). The **split-borrow is a real
constraint**: the current loop borrows `rng` and `hmac_keys` as *separate fields*
simultaneously (e.g. `keygen_ack(&mut secrets, rng)`), which accessor methods
returning `&mut Self::X` cannot reproduce — hence `parts()`. (Alternative: keep
separate generic fields on `DeviceLoop` instead of a bundle — noted for review;
bundle+`parts` is the trait-minimal choice.)

```rust
pub struct HalParts<'a, H: DeviceHal> {
    pub upstream:   &'a mut H::Upstream,
    pub downstream: &'a mut H::Downstream,
    pub rng:        &'a mut H::Rng,
    pub secrets:    &'a mut H::Secrets,    // the share-encryption DeviceSecretDerivation
    pub firmware:   &'a mut H::Firmware,
}
```

All five come from the *one* `&mut self` borrow in `parts()` and point at disjoint
fields, so the loop can hold several at once (e.g. `keygen_ack(p.secrets, p.rng)`).
No `display` (`FrostyUi` owns it) and no `flash` (the loop holds the split
`FlashPartition` handles). `now_ms`/`next_touch`/`downstream_present` stay plain
`&self`/`&mut self` methods — they don't need the disjoint borrow.

**Storage is an NVS partition with an *external* backing, not a raw `&mut
NorFlash`.** The loop init `split_off_front`s the NVS `FlashPartition` into
header/share/reserved/nonce, builds `FlashHeader::new(...)`, `MutationLog::new(share,
nvs)`, `NonceAbSlot::load_slots(...)`, and keeps `full_nvs` for the recovery `Erase`
(`esp32_run.rs:116–144`). `FlashPartition<'flash, S>` is a **copyable handle over a
`RefCell<S>`** that does *not* implement `NorFlash`. Crucially the backing
`RefCell<Storage>` must live **outside** both the HAL and the loop — exactly as
today, where `Resources` holds a `FlashPartition` over an externally-supplied
`RefCell<FlashStorage>` (`resources.rs:47–52`). So **`DeviceLoop::new(hal, ui, nvs:
FlashPartition<'flash, H::Storage>)` takes the partition as a separate argument**
(not `hal.nvs()`): the loop owns `hal` *and* stores the split `FlashPartition<'flash,
…>` handles, which borrow the external `RefCell`, never `hal` — avoiding the
self-referential shape an `nvs(&self)` accessor would create. `type Storage` only
names the flash type; `HalParts` carries no flash (poll-time access is through the
held handles).

**Two serial links + downstream presence.** The device daisy-chains: an
**upstream** link (to coordinator/parent) and a **downstream** link (to a child),
plus a GPIO downstream-detect — hence `type Upstream`/`type Downstream` (both in
`HalParts`) and `downstream_present()`. The loop drives downstream
magic-bytes/state and forwards downstream↔upstream traffic exactly as today
(`esp32_run.rs:261–332`); the upgrade takeover gets the downstream link only when
established (`:403–421`). On host the downstream link is a **null `embedded_io`
endpoint** and `downstream_present()` is `false` (star topology; daisy-chain
deferred) — the smoke test covers this disconnected-downstream path.

**Reset is a terminal outcome, not an esp call in the core — at *two* points.**
(1) *Poll-time:* `reset(upstream_serial)` sends the upstream reset signal then
calls `esp_hal::reset::software_reset()` (`esp32_run.rs:801–806`), invoked after
upgrade takeover and after `ErasePoll::Reset` (`:422,478–479`). (2) *Init-time:*
`DeviceLoop::new` runs a recovery `Erase` to completion then `software_reset()`
when `read_header()` is `None` and NVS is non-empty (`:120–126`). Both must surface
as values, not esp calls: `poll()` returns **`Poll::ResetRequested`** (after
sending the upstream reset signal), and construction returns
**`InitOutcome::{Ready(DeviceLoop), ResetRequested}`** (after the recovery erase).
The device shell (the bin) performs `software_reset()` in both cases. No esp reset
lives in `frostsnap_embedded`, and the sim can *observe* both reset requests.

**New seam 2 — `FirmwareServices`** (device-only OTA + attestation, kept out of
the portable core — exactly the concern the sim drops):

```rust
pub trait FirmwareServices {
    fn firmware_digest(&self) -> Sha256Digest;               // for Announce
    /// Handle Upgrade/Challenge coordinator messages; the esp impl may take over
    /// serial (enter_upgrade_mode). Returns the next action — incl. ResetRequested,
    /// the *only* reason this trait carries a reset (the esp takeover ends in reset).
    fn handle(&mut self, msg: &CoordinatorSendBody, io: FirmwareIo<'_>) -> FirmwareAction;
    fn poll(&mut self, ui: &mut impl UserInteraction) -> FirmwareAction;
}
// FirmwareAction { None, Send(DeviceSendBody), ResetRequested }
```

The core loop forwards the `Upgrade(..)`/`Challenge(..)` arms (and the upgrade
`poll`) to `firmware`, reads `firmware_digest()` for `Announce`, and on
`FirmwareAction::ResetRequested` sends the upstream reset signal over `Upstream`
and returns `Poll::ResetRequested` (the bin shell does the esp reset). All
OTA/RSA/DS stays in the esp impl. **Production unchanged**: `EspFirmware` carries
today's `start_upgrade`/`poll`/`enter_upgrade_mode`/challenge-signing verbatim,
ending the takeover with `FirmwareAction::ResetRequested`.

**Host/sim punts firmware entirely — by construction it never runs.** `SimFirmware`
seeds `firmware_digest()` with **the app's *latest* firmware digest**, so the
coordinator never decides an upgrade is needed and never sends `Upgrade`/`Challenge`;
`handle`/`poll` therefore **`panic!`/`unreachable!`** (documenting the invariant).
No virtual OTA, no reset, no upgrade sim — a real OTA simulation is explicitly
**out of scope / future work**, not half-built here.

So the **new surface is two traits** (`DeviceHal`, `FirmwareServices`) + the
`TouchEvent`/`HalParts`/`FirmwareIo`/`FirmwareAction` plumbing types, reusing
`DeviceSecretDerivation` and the standard traits. RNG seeding from fixed-entropy (`efuse.rs:502
mix_in_rng`) stays device-side at init; the loop just gets a seeded `Rng`.

### UI / touch split (`frosty_ui.rs`, `touch_handler.rs` are NOT portable as-is)

These are esp-coupled today: `frosty_ui.rs` imports `esp_hal::prelude::*` +
`TouchReceiver` (`:4–5`), defines `DeviceDisplay` over mipidsi/SPI/GPIO (`:23–35`),
and owns a `TouchReceiver` + TIMG timer that `poll`/`force_redraw` read
(`:402–423,530–535`); `touch_handler.rs` decodes `frostsnap_cst816s`
`TouchReceiver`/`TouchGesture` (`:3,18,24–38`). So this is a **split, not a
relocation**:
- **Portable → `frostsnap_embedded`:** a **generic `FrostyUi<D: DrawTarget<Color =
  Rgb565>>`** owning the widget tree + the generic display `D`, plus the
  touch-*interpretation* that turns a portable `TouchEvent` into
  `handle_touch`/`handle_vertical_drag` calls. It owns **no** timer/receiver and
  never names `esp_hal`/`frostsnap_cst816s`/`mipidsi`/TIMG.
- **Stays in `device/` (`EspHal`):** the concrete `DeviceDisplay` (mipidsi ST7789
  over SPI) construction; the TIMG timer (surfaced as `DeviceHal::now_ms`); the
  **CST816S `TouchReceiver`/`TouchGesture` → `TouchEvent` conversion** plus
  `touch_calibration.rs` (panel-specific), surfaced as `DeviceHal::next_touch`.
  On host, `D` = an off-screen framebuffer `DrawTarget` and `next_touch` yields
  scripted/tray `TouchEvent`s.
- **`UserInteraction` takes the clock/touch from the loop** (the forced trait
  change): since `FrostyUi` no longer owns a timer/receiver, its time/draw methods
  receive the clock — `poll(&mut self, now_ms: u64, touch: Option<TouchEvent>)`,
  other draw methods take `now_ms`, and `force_redraw` sets a dirty flag the next
  `poll` honours. The loop feeds `DeviceHal::now_ms()` + `next_touch()` in.

### Sketch — the esp32c3 `DeviceHal` impl

Illustrative (not exhaustive). `device/` wraps today's peripherals. Note the
backing `RefCell<FlashStorage>` is owned by the bin and the NVS `FlashPartition`
is passed to `DeviceLoop::new` separately — so it is *not* a field here.

```rust
struct EspHal<'a> {
    upstream:   EspUpstream<'a>,     // embedded_io adapter over UART1 / USB-JTAG
    downstream: EspDownstream<'a>,   // embedded_io adapter over UART0
    downstream_detect: Input<'a, AnyPin>,
    rng:        ChaCha20Rng,
    hmac:       EfuseHmacKeys<'a>,   // .share_encryption: DeviceSecretDerivation; .fixed_entropy
    firmware:   EspFirmware<'a>,     // OtaPartitions + Sha + Rsa + HardwareDs + active digest
    timer:      TimgTimer<Timer0<TIMG0>, Blocking>,
    touch:      TouchReceiver,       // CST816S queue + calibration
}

impl<'a> DeviceHal for EspHal<'a> {
    type Upstream   = EspUpstream<'a>;
    type Downstream = EspDownstream<'a>;
    type Rng        = ChaCha20Rng;
    type Storage    = esp_storage::FlashStorage;
    type Secrets    = EfuseHmacKey<'a>;     // the share-encryption key (impl DeviceSecretDerivation)
    type Firmware   = EspFirmware<'a>;

    fn parts(&mut self) -> HalParts<'_, Self> {
        HalParts {
            upstream:   &mut self.upstream,
            downstream: &mut self.downstream,
            rng:        &mut self.rng,
            secrets:    &mut self.hmac.share_encryption,
            firmware:   &mut self.firmware,
        }
    }

    fn now_ms(&self) -> u64 { self.timer.now().duration_since_epoch().to_millis() }

    fn next_touch(&mut self) -> Option<TouchEvent> {
        // CST816S gesture/point -> portable TouchEvent (calibration applied here)
        self.touch.dequeue().map(calibrate_to_touch_event)
    }

    fn downstream_present(&self) -> bool { !self.downstream_detect.is_high() } // active-low: connected when the pull-up reads low (mirrors esp32_run.rs:261)

    fn device_keypair_seed(&mut self, seed: &[u8; 32]) -> [u8; 32] {
        // exactly today's FlashHeader::device_keypair hash, via the fixed-entropy eFuse key
        self.hmac.fixed_entropy.hash("frostsnap-device-keypair", seed).unwrap()
    }
}
```

The host/sim impl mirrors this: in-mem `embedded_io` pipes (upstream = coordinator
transport, downstream = null), a seeded `ChaCha20Rng`, a software
`DeviceSecretDerivation` over fixed dev keys, `SimFirmware` (digest = app's latest),
a monotonic clock, and scripted `next_touch`.

### Code movement
- **Into `frostsnap_embedded`** (new `ui` feature pulling `frostsnap_widgets` +
  `embedded-graphics`, storage modules still build without it): `esp32_run.rs`
  (`DeviceLoop`, generic over `H: DeviceHal`), `ui.rs`, `widget_tree.rs`,
  `root_widget.rs`, a **generic `FrostyUi<D: DrawTarget>`** + the portable
  touch-*interpretation* (see *UI / touch split* — the concrete display, the
  CST816S→`TouchEvent` conversion, and `touch_calibration.rs` stay device-side),
  the framing half of `io.rs` (as a bincode `Reader`/`Writer` adapter over
  `embedded_io` + `now_ms` for the per-byte timeout, replacing the
  `timer::Timer`-bound `SerialInterface`), **plus the flash/erase modules the loop
  imports** — `flash/header.rs` (`FlashHeader<'a,S>` + the `device_keypair`
  builder), `flash/log.rs` (`MutationLog<'a,S>`, `Mutation`), and `erase.rs`
  (`Erase`). These are **already hardware-agnostic** (generic over `NorFlash` /
  built on `frostsnap_embedded::{FlashPartition, NorFlashLog}` + the `UI` trait),
  so they *must* move with the loop — leaving them in `device/` while the loop
  moves would force `frostsnap_embedded → device`, an illegal reverse dependency.
  `device_keypair` derives via `DeviceHal::device_keypair_seed` (fixed-entropy
  hash) instead of `&mut EfuseHmacKey`.
- **Crate-root portable helpers move too.** The moved modules import items
  currently at `device/src/lib.rs`: `UpstreamConnection` + `UpstreamConnectionState`
  / `DownstreamConnectionState` (`lib.rs:58–162`), the `Instant`/`Duration` `fugit`
  aliases (`:164–165`), `DISPLAY_REFRESH_MS` (`:12`), and the `log!`/`log_and_redraw!`
  macros (`:15–31`, gated on `debug_log`, redraw via the `UI` trait). All portable
  → move into `frostsnap_embedded` (which gains a `fugit` dep and a `debug_log`
  feature). `device/src/lib.rs` then keeps only its esp module declarations + any
  esp-specific root items, re-exporting from `frostsnap_embedded` where the bins
  need it. (Same reverse-dependency rule: leaving these in `device/` is illegal.)
- **Stays in `device/`** as the esp `DeviceHal`/`FirmwareServices` impls + bins:
  `peripherals.rs`, `resources.rs`, `ds.rs`, `efuse.rs`, `ota.rs`, `partitions.rs`
  (ESP partition-table discovery), `flash/genuine_certificate.rs` (factory genuine
  cert — pairs with `FirmwareServices`), `secure_boot.rs`, `uart_interrupt.rs`,
  `panic.rs`, `stack_guard.rs`, `bin/`, `factory/`. `device/` gains `EspHal`
  (display/flash/serial-adapter/rng/`EfuseHmacKeys`/`EspFirmware`) and constructs
  the loop in the bins. (`DeviceLoop`'s `full_nvs`/`mutation_log`/`erase_state`
  fields move with the loop, now generic over `H::Storage`.)

## Steps
1. `frostsnap_embedded`: add the `ui` feature (+ `fugit` dep, `debug_log` feature); define `DeviceHal`, `FirmwareServices`, `HalParts`, `FirmwareIo`, `TouchEvent`.
2. Move the agnostic UI/loop modules **and** `flash/header.rs`, `flash/log.rs`, `erase.rs`, **and the crate-root helpers** (`UpstreamConnection` + state enums, `Instant`/`Duration` aliases, `DISPLAY_REFRESH_MS`, `log!`/`log_and_redraw!`) into `frostsnap_embedded` (the loop's `full_nvs`/`mutation_log`/`erase_state` come with it, generic over `H::Storage`). Make `DeviceLoop` generic over `H: DeviceHal`; replace esp types with bounds; route the `Upgrade`/`Challenge` arms + upgrade poll + Announce digest through `firmware`, the `DataErase` arms + erase poll through the moved `Erase`, drive both `Upstream`/`Downstream` links + `downstream_present()`, and convert both reset paths into outcomes — `poll()` → `Poll::ResetRequested` (after the upstream reset signal), and `DeviceLoop::new` → `InitOutcome::{Ready, ResetRequested}` for the init-time recovery-erase reset (`:120–126`). Reduce `device/src/lib.rs` to esp module decls + re-exports.
3. Add the bincode-`Reader`/`Writer`-over-`embedded_io` serial adapter (timeout via `now_ms`).
4. Move `device_keypair` + `DeviceSecretDerivation` usage in-core, taking `&mut Self::Secrets` / `device_keypair_seed`; `DeviceLoop::new(hal, ui, nvs)` takes the NVS `FlashPartition` as a separate arg (backed by a `RefCell<Storage>` the caller owns) and `split_off_front`s the header/share/reserved/nonce partitions — no `nvs(&self)`, so the split handles store alongside the owned `hal` without borrowing it.
5. `device/`: implement `EspHal` + `EspFirmware` (relocating today's OTA/genuine/digest logic unchanged, ending the takeover with `FirmwareAction::ResetRequested`); keep `flash/genuine_certificate.rs` + ESP partition discovery device-side; adapt the upstream/downstream UART/JTAG to `embedded_io` and wire `downstream_detect` into `downstream_present()`; the bin owns the `RefCell<esp_storage::FlashStorage>` and passes the NVS `FlashPartition` into `DeviceLoop::new` (as today via `Partitions`/`Resources`); seed RNG at init as today.
6. Update `bin/{frontier,legacy}.rs` to build `EspHal`, run the loop, and call `esp_hal::reset::software_reset()` for **both** reset sources: `DeviceLoop::new` → `InitOutcome::ResetRequested` and `poll()` → `Poll::ResetRequested` (the latter covers the firmware takeover's `FirmwareAction::ResetRequested`).
7. Host smoke test (`frostsnap_embedded`, `std`+`ui`): own `let storage = RefCell::new(<RAM NorFlash>)`, build `let nvs = FlashPartition::new(&storage, …)`, derive the device keypair via a software `device_keypair_seed`, then construct **`DeviceLoop::new(stub_hal, FrostyUi<OffscreenDisplay>, nvs)`** — `stub_hal` supplying in-mem `embedded_io` serial, seeded rng, software `DeviceSecretDerivation`, `SimFirmware` (digest = the app's latest → no upgrade ever offered; its upgrade path is `unreachable!`), fake clock/touch; the UI owning the off-screen `DrawTarget`, the **downstream link stubbed** (null `embedded_io`, `downstream_present()` = false). The loop splits the NVS into header/share/nonce + loads `FlashHeader`/`MutationLog` — proving the split handles store alongside the owned `stub_hal` without borrowing it. Pump `poll()` so fake `now_ms` + scripted `TouchEvent`s flow through (a frame renders, a tap reaches a widget); drive a `DataErase` to completion against the RAM flash and assert `poll` returns **`Poll::ResetRequested`** afterwards (no esp reset performed). Also cover the **init reset path**: a non-empty RAM NVS with no `FlashHeader` → `DeviceLoop::new` returns **`InitOutcome::ResetRequested`** after the recovery erase. This proves the chosen ownership model compiles, not just a standalone `FrostyUi`.

## Verification
- `cargo build -p frostsnap_embedded` (host, default + `ui`) compiles — no esp deps.
- `device/` still builds for esp32 (riscv32); both bins link; OTA/genuine/upgrade behavior unchanged (logic relocated, not rewritten).
- Host smoke test constructs `DeviceLoop` and runs `poll()` (with `SimFirmware`) without panicking; it loads a `FlashHeader` + `MutationLog` and drives a `DataErase` to completion over RAM flash. Firmware upgrade is punted by construction: the seeded digest equals the app's latest so no upgrade is ever offered, and `SimFirmware`'s upgrade path is `unreachable!`.
- No reverse dependency: `frostsnap_embedded` does not depend on `device` (the moved `flash`/`erase`/root-helper modules carry their portable logic with them).
- Two serial links + downstream-presence are modeled (`Upstream`/`Downstream` + `downstream_present()`); the smoke test covers the disconnected-downstream path. Both reset points are returned outcomes — `poll()` → `Poll::ResetRequested` and `DeviceLoop::new` → `InitOutcome::ResetRequested` — the esp `software_reset()` lives only in the bin shell; the smoke test asserts both (DataErase poll reset + init recovery-erase reset) rather than resetting.
- The chosen ownership model compiles + is exercised end-to-end: `DeviceLoop::new(stub_hal, FrostyUi<OffscreenDisplay>)` renders a frame and a scripted `TouchEvent` reaches a widget (not just a standalone `FrostyUi`); the moved code names no `esp_hal`/`frostsnap_cst816s`/`mipidsi`/TIMG types; `DeviceHal` has no `Display`.
- Storage: the NVS `FlashPartition` is passed into `DeviceLoop::new` separately, backed by a `RefCell<Storage>` owned outside the loop (no `nvs(&self)` self-reference); `HalParts` carries no flash; the smoke test proves the split header/share/nonce handles store alongside the owned HAL and compile.
- **New trait surface = two traits** (`DeviceHal`, `FirmwareServices`) + reuse of `DeviceSecretDerivation`/standard traits. Reviewer mandate: push back if `FirmwareServices` can be merged/shrunk or `DeviceHal` trimmed.

## Open questions
- `FirmwareIo` shape for the **esp** `enter_upgrade_mode` takeover (streams firmware over upstream/optional-downstream, then resets via `FirmwareAction::ResetRequested`). Esp-impl-only — the sim never reaches it (digest seeded to the app's latest), so this doesn't gate the host path.
- Whether `Secrets` (share-encryption) and `device_keypair_seed` (fixed-entropy) should be one associated type exposing both keyed hashes, or stay split as drafted.
- `HalParts` split-borrow vs separate generic fields on `DeviceLoop` (borrow ergonomics vs generic-param count).
- `embedded_io` `ReadReady` mapping from the esp interrupt-fed RX queues; behaviour of the per-byte read timeout under `now_ms`.
