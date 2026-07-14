# sim-1-virtual-device-hal
# sim-1: virtual device HAL (software crypto + sim peripherals)

## Goal
Stand up a host-compilable `tools/virtual_device` crate (package `frostsnap_virtual_device`)
that runs the **real** lifted `DeviceLoop` + **real** `FrostyUi` over software peripherals — the
device half of the app sim. This is the first piece of the AUTOMATION_RESEARCH epic (Axis 1
crypto + Axis 2 runtime), and it replaces the smoke-test stubs with honest implementations.

## Core model (read first)
The sim is **not a fake device**. It is the identical `frostsnap_embedded::DeviceLoop` and
`FrostyUi` the esp firmware runs; only the *leaf* `DeviceHal` peripherals change. Therefore:

- The crypto must be **real**, not constant. The smoke-test doubles `FakeSecrets`
  (`frostsnap_embedded/src/device_loop.rs:845`, `keyed_hash` → `[1u8;32]`,
  `get_share_encryption_key`/`derive_nonce_seed` → `[0u8;32]`) and `StubFirmware`
  (`device_loop.rs:870`) exist only to drive the loop lifecycle. A constant keyed-hash is a
  degenerate device key and a constant `derive_nonce_seed` is catastrophic nonce reuse the
  moment we sign.
- **Leaf vs portable, precisely (the model the whole epic rests on — "only the *leaf* changes"):**
  the only per-platform thing is the keyed-hash **primitive** (`KeyedHash::keyed_hash`,
  `flash_header.rs:9`): esp = HMAC peripheral over an eFuse key, sim = software HMAC-SHA256 over a
  RAM key. `DeviceSecretDerivation` (`frostsnap_core/src/device.rs:906`) is **portable** — it is a
  pure function of `keyed_hash(domain, input)`: pack typed fields into a fixed byte layout, then
  hash (the 128-byte `share-encryption` src and the `nonce-seed` input incl.
  `index.to_be_bytes()`, `efuse.rs:516-552`). It must live in **exactly one place**, not be
  re-implemented per platform — otherwise sim/esp fidelity is a copy-paste convention that drifts
  silently on the most safety-critical path (nonce derivation). Today that layout sits, wrongly,
  inside the esp leaf; this plan moves it to a shared portable impl over the `KeyedHash` seam and
  has both esp and sim consume it, so "sim matches hardware" is a compile-time fact, not a hope.
- **No SDL / `embedded-graphics-simulator` dependency.** `frostsnapp/rust` will depend on
  this crate (plan sim-4), so it must build SDL-free and be a *default* workspace member
  (unlike `tools/widget_simulator`, excluded for SDL). Use
  `frostsnap_widgets::vec_framebuffer::VecFramebuffer<Rgb565>`
  (`frostsnap_widgets/src/lib.rs:71`) as the `DrawTarget` — confirmed pure-Rust, no SDL.
- Genuine-check stays **off** (Axis 9): `SimFirmware` answers `Challenge` with
  `FirmwareAction::None` and is never offered an upgrade. Honest stub, not a security hole.

## Committed ownership model (the load-bearing decision)
`DeviceLoop` stores **borrows**, not owners: it holds `HalParts<'a, H>`, `&'a mut U`,
`&'a dyn Clock`, and a `FlashPartition<'a, S>` that itself borrows an external `RefCell<S>`
(`device_loop.rs:59-97`). So a struct that owns `SimHal`/`FrostyUi`/clock/flash **and** owns a
`DeviceLoop` borrowing those same fields is self-referential and not expressible in safe Rust.
The esp shell dodges this by keeping `hal`/`ui`/`clock` as locals in a never-returning `run()`.

The sim commits to this shape — **owned parts + a stack-local runner; the `DeviceLoop` is never
stored**:

- `VirtualDevice` **owns** the inputs and nothing borrowed:
  `{ flash: RefCell<RamFlash>, hal: SimHal, ui: FrostyUi<FramebufferDisplay, SimClock, TouchQueue>, clock: SimClock }`.
- The outside world holds **cloneable handles** captured at construction, independent of the
  owned struct: `SharedFramebuffer` (frame export / PNG), `TouchQueue` (inject touch), and the
  serial `HostEnd` (the coordinator byte endpoint, consumed in sim-2). These are `Arc`-backed,
  so a reader can export frames / inject touch while the loop runs.
- `VirtualDevice::new(config) -> VirtualDevice` is the public constructor (the `Arc`-backed
  handles are reachable via getters or returned alongside).
- A **single** borrowed `DeviceLoop` is kept alive for the duration of a *session* — it is
  **not** reconstructed per tick. Per-tick reconstruction would drop the loop's runtime state
  (upstream/downstream connection state, outbox/inbox, nonce batches, pending device name,
  erase/firmware progress, magic-byte timeout counters, soft-reset — `device_loop.rs:73-83`), so
  repeated polls would be repeated *boots* and would mask bugs. The session is a separate,
  caller-owned value that *borrows* the parts, so nothing is self-referential:
  `fn session(&mut self) -> InitOutcome<VirtualDeviceSession<'_>>` constructs
  `FlashPartition::new(&self.flash, …)` + `DeviceLoop::new(&mut self.hal, &mut self.ui,
  &self.clock, nvs)` from **disjoint field borrows of `&mut self`** (allowed) and returns a
  `VirtualDeviceSession<'a> { loop_: Box<DeviceLoop<'a, SimHal, FrostyUi<…>>> }` that borrows the
  `VirtualDevice` for its lifetime.
- `VirtualDeviceSession::poll_once(&mut self, downstream_present) -> Poll` advances **that same**
  loop; the `Arc`-backed frame/touch/serial handles are cloneable from either `VirtualDevice` or
  the session and stay valid across polls.
- sim-2's per-thread runtime is then `run(self)` → `thread::spawn(move || { let mut s =
  self.session()…; loop { s.poll_once(present) } })` — `self` owned by the closure, the one
  session (and its single loop) lives for the whole thread. No leak, no `'static`
  self-reference.

This is the explicit answer to "where does the borrowed loop live": in a caller-owned
`VirtualDeviceSession` that borrows the parts and holds **one** `DeviceLoop` for the whole
session — never reconstructed per tick, never a field of `VirtualDevice`.

## Tasks
1. Scaffold `tools/virtual_device` (package `frostsnap_virtual_device`, std lib). Add to
   workspace `members` AND `default-members` in root `Cargo.toml` (must build under plain
   `cargo check`). Depend on `frostsnap_embedded` (features `ui`,`std`), `frostsnap_core`,
   `frostsnap_comms`, `frostsnap_widgets` (feature `std`), `embedded-graphics`,
   `embedded-storage`, `rand_chacha`, `rand_core`, `bitcoin` (its `hashes` give HMAC-SHA256, no
   new external dep), `image` (png).
2. Shared portable derivation (do this FIRST, it's the source of truth): in `frostsnap_embedded`
   add `pub struct ShareEncryptionSecrets<H: KeyedHash>(pub H)` with
   `impl<H: KeyedHash> DeviceSecretDerivation for ShareEncryptionSecrets<H>` carrying the packing
   from `efuse.rs:516-552` **verbatim** (orphan rule is fine: local type, foreign trait, and
   `frostsnap_embedded` already deps `frostsnap_core`). This is the one place the byte layout +
   domain strings + `index.to_be_bytes()` live.
3. esp refactor (remove the duplication the lift left): `EfuseHmacKey` keeps **only** its
   `KeyedHash` impl; DELETE its bespoke `DeviceSecretDerivation` (`efuse.rs:516-552`).
   `EfuseHmacKeys.share_encryption` becomes `ShareEncryptionSecrets<EfuseHmacKey>` and
   `EspHal::Secrets = ShareEncryptionSecrets<EfuseHmacKey>` (`device/src/esp32_run.rs`). esp must
   still build (`cargo +esp check`).
4. Sim secrets: a `SimKeyedHash { key: [u8;32] }` implementing **only**
   `frostsnap_embedded::KeyedHash` (`flash_header.rs:9`) via software HMAC-SHA256 with the same
   length-prefixed-domain construction the esp HMAC uses (`efuse.rs:473-500`). `SimHal::Secrets =
   ShareEncryptionSecrets<SimKeyedHash>`. Two distinct keys for the `keypair_hasher`
   (fixed-entropy) seam vs the share-encryption `Secrets` seam (`device_hal.rs:127-133`), derived
   from a sim seed via labelled SHA256. The sim re-implements the *primitive* only, never the
   packing.
5. `SimFirmware: FirmwareServices` (`device_hal.rs:80`): fixed `firmware_digest`; `handle`
   returns `None` for `Challenge`, `unreachable!` for upgrade msgs; `poll`/`confirm`/`cancel`
   inert. Document the genuine-off contract.
6. RAM `NorFlash` (`RamFlash`, promote `FakeFlash`, `device_loop.rs:788`); seeded `ChaCha20Rng`
   (`RngCore+CryptoRng`); a monotonic `SimClock` (`Clock`, `device_hal.rs:45`, `Instant`-backed
   so all clones share one timeline); a `TouchQueue` (`TouchSource`, `Arc`-backed so touch is
   injected from outside).
7. Framebuffer display: a `FramebufferDisplay` over a shared `VecFramebuffer<Rgb565>`, plus
   `export_rgba() -> (w,h,Vec<u8>)` (RGB565→RGBA8888, the conversion the Flutter tray needs in
   sim-5) and `save_png(path)` via the `image` crate (the Rust-side debug artifact).
8. Assemble `SimHal: DeviceHal` (the `parts()` split-borrow + `keypair_hasher()`,
   `device_hal.rs:116-134`) and the real `FrostyUi::new(display, clock, touch)`. Implement
   `VirtualDevice::new` + the `session()` → `VirtualDeviceSession` runner (one persistent boxed
   `DeviceLoop` per session, `poll_once` advancing *that* loop) per the ownership model above.
   The in-memory serial `ByteIo`/`HostEnd` primitive is built here (the device needs a
   `ByteIo`); a `disconnected()` device (no peer) is enough for sim-1, with the connected
   coordinator endpoint wired in sim-2.

## Acceptance
- `cargo check` (default members) and `cargo check -p frostsnap_virtual_device` green; **esp
  still builds** (`cargo +esp check` for the `device` lib/bins) after the `efuse.rs`/`EspHal`
  refactor; a dependency check (e.g. `cargo tree`) shows **no**
  `sdl2`/`embedded-graphics-simulator` pulled by `frostsnap_virtual_device`.
- `DeviceSecretDerivation` exists in exactly one place: `ShareEncryptionSecrets<H: KeyedHash>` in
  `frostsnap_embedded`, consumed by both `EspHal` (`ShareEncryptionSecrets<EfuseHmacKey>`) and
  `SimHal` (`ShareEncryptionSecrets<SimKeyedHash>`); no bespoke `DeviceSecretDerivation` impl
  remains in `efuse.rs` or the sim crate.
- `VirtualDevice::new` compiles as the public API, and a fresh device runs a **persistent
  session**: `let mut session = device.session()?; session.poll_once(false);
  session.poll_once(false);` advances the *same* `DeviceLoop` across ticks (runtime state
  preserved, loop not rebuilt between ticks), and a frame is exported (`export_rgba`/`save_png`)
  through the `Arc`-backed handles — no self-reference workaround.
- Unit tests: (a) derived device keypair (`FlashHeader::init` → `Header::device_keypair`) is
  deterministic for a given seed and key-dependent (a different fixed-entropy key gives a
  different public key) — i.e. non-degenerate, real crypto; (b) the **shared**
  `ShareEncryptionSecrets<SimKeyedHash>` `get_share_encryption_key`/`derive_nonce_seed` outputs
  are non-constant and vary with their inputs/keys (exercising the one portable impl over a real
  `KeyedHash`); (c) a booted device (`poll_once` a few times) renders ≥1 frame and `save_png`
  writes a non-blank 240×280 PNG.

## Non-goals / deferred
No coordinator transport wiring / no per-thread `run` (sim-2 — only the `ByteIo`/`HostEnd`
primitive and the `session()` shape land here). No Flutter (sim-4+). No daisy-chain /
multi-device. No software-genuine DS (Axis 9 "later").

## Depends on
Nothing — builds on the finished `lift-deviceloop-to-frostsnap-embedded`.
