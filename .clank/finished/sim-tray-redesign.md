# sim-tray-redesign
# A frontend-design pass on the sim debug tray — make it nice and ergonomic

## Goal
Redesign the SIM debug tray (`frostsnapp/lib/sim_device_tray.dart`) so it looks good and is
pleasant to use. It's the surface a developer stares at all day while driving the sim, so dev
happiness is the point. Free to use more horizontal space — widen the tray as needed.

## Why
The tray works but is cramped and visually noisy: a fixed 320px panel squeezes a dense "Test BTC"
form plus TWO device columns (Chain / Disconnected) with tiny live screens, small label-size
type, an overflowing raw electrum URL, and sections that run together with no clear hierarchy.
It reads as utilitarian-ugly. Nothing about the layout is load-bearing for tests (automation
drives everything through `./simctl`, not by tapping the tray — see the CLI-parity rule), so the
presentation is free to change.

## Scope (presentation only, sim-only)
- ONLY `lib/sim_device_tray.dart` (and the tray width constant / its mount in `main.dart` if
  widening). No behavioural change: the same `DevicePool` actions (plug/unplug all, per-device
  connect/disconnect, reorder, live screen, touch) and the same `SimFaucet` actions (balance,
  electrum URL, Mine, generic fund-an-address) — only how they look and lay out.
- Stays gated on `kSim`; zero effect on the production app. esp/embedded untouched.

## Approach
1. **Design pass** — apply the frontend-design skill. Decide a layout that gives each concern room:
   a clean header, a well-spaced **faucet card** ("Test BTC": balance + electrum status + Mine +
   a roomy fund-an-address form with clear labels and result/error feedback), and a **devices
   area** with comfortably sized device cards (larger live screens, legible names, obvious
   connect/disconnect/reorder affordances). Use Material 3 `colorScheme`/`textTheme` consistently
   (cards, dividers, spacing scale, tonal surfaces) instead of ad-hoc sizes. Widen the tray to a
   comfortable width; consider stacking the device groups vertically if that reads better than two
   skinny columns.
2. **Implement** the restructured tray, keeping all current capabilities and the live-frame
   rendering / foreground-before-screenshot behaviour intact.
3. **Self-verify**: before/after screenshots (`./simctl shot`), confirm every control still works
   driven through `./simctl` (devices: connect/disconnect/chain/reorder; faucet: balance/mine/fund),
   `dart analyze` + `dart format` clean, and a driver test (`./simctl test keygen`) still green.

## Acceptance
- The tray looks clean and is ergonomic: clear visual hierarchy, comfortable spacing/typography,
  no overflow, sensible use of width — verified by before/after screenshots.
- All existing tray capabilities remain and behave identically (CLI-driven functional check).
- Sim-only, presentation-only: no production/app behaviour change, no backend change, esp/embedded
  untouched; analyze + format clean; the driver suite still passes.

## Depends on
The sim tray (sim-12/13) and the Test BTC faucet column (regtest-bitcoin-receiving). Pure
follow-up polish — no new capability.
