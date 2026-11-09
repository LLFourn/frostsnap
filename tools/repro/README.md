# repro

`repro` rebuilds a Frostsnap desktop release from its public source, so you can check that the app
we ship was built from that source and nothing else. It pins and checks everything the build uses,
so that two builds of a release come out byte for byte the same wherever they run.

## Checking a release

You need the release's tag, its signed `firmware.bin` (from the same GitHub release), and the
bundle you want to check.

```sh
git clone https://github.com/frostsnap/frostsnap && cd frostsnap
git checkout v0.5.0
cargo build --release --manifest-path tools/repro/Cargo.toml
alias repro=$PWD/tools/repro/target/release/repro
```

**On macOS:**

```sh
repro verify macos --commit v0.5.0 --firmware firmware.bin \
  --out ~/repro-out --against Frostsnap.app
```

**On Linux:**

```sh
repro verify linux --commit v0.5.0 --firmware firmware.bin \
  --out ~/repro-out --against frostsnap
```

`verify` builds the release from scratch, then compares the result with `--against`, file by file.
It exits 0 only if both have the same paths, every file has the same bytes and permission bits, and
every symlink the same target. Otherwise it lists the entries that differ.

`repro build` makes the same build without comparing. It writes the bundle, its `manifest` (one line
per entry: path, type, and a file's mode and sha256 or a symlink's target) and `build.env` (what
went in) to `--out`. `repro compare <a> <b>` compares two bundles or manifests.

A build takes 10 to 30 minutes, and needs about 15 GB of disk and a network connection. It always
bundles the release's signed firmware, and checks its secure-boot signature first, as the release
build does.

### What you need

**macOS:**
- Rust 1.95.0: `rustup toolchain install 1.95.0`. `repro` checks the `rustc` on your `PATH` and
  stops if it is a different version.
- The Xcode named in `macos.toml`, installed at the path given there (`/Applications/Xcode_27.1.app`,
  where GitHub's `xcode-27` image keeps it). `repro xcode-hash /Applications/Xcode_27.1.app` prints
  the hash it must match.

**Linux**, any distribution:
- `bubblewrap`, and unprivileged user namespaces (on by default almost everywhere). Arch:
  `pacman -S bubblewrap`. Debian or Ubuntu: `apt install bubblewrap uidmap`.
- A subordinate uid and gid range for your user, of at least 65535 ids, in `/etc/subuid` and
  `/etc/subgid`, and `newuidmap`/`newgidmap`. Most distributions set this up for every user; if not,
  `sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 $USER`.
- On Ubuntu 23.10 and later, AppArmor blocks unprivileged user namespaces:
  `sudo sysctl kernel.apparmor_restrict_unprivileged_userns=0`.
- `curl`, `tar` and `git`, and Rust to build `repro` itself.
- The build runs for the machine's own architecture, `x86_64` or `aarch64`; `--arch` picks the other
  one if the machine can run its binaries.

**A Mac building Linux:** `tools/repro/linux/lima.yaml` makes a Lima VM with everything above, for
`aarch64`, and `x86_64` through Rosetta.

## What it proves

If `verify` passes, the bundle you checked is exactly what the public source at that tag builds to,
with the pinned toolchain. The design keeps everything about the build machine out of the build:

- **Every input is pinned by content**, in `repro.toml`, `macos.toml` and `linux.toml`, and checked
  when it is used, not only when it was downloaded:
  - Flutter, by git commit; its engine downloads and its Dart SDK, by hash.
  - The code generators and CocoaPods' gems, by the hash of each file.
  - Xcode, by the hash of its whole installed tree.
  - Every crate and Dart package, through the source's lockfiles.
  - On Linux, the whole system the app builds against: an Ubuntu base image, every package from one
    snapshot of the Ubuntu archive, and the Rust toolchain, each by hash. The installed package set
    is checked against its own hash before anything is built.
- **Builds start clean.** Every build reinstalls its tools from re-checked downloads, so nothing a
  previous build left behind can reach the next.
- **Builds the release, not your checkout.** The source comes from `git archive <commit>`.
- **Same paths and environment everywhere.** Everything that can reach a binary lives under one fixed
  path, and every build command runs with a fixed, minimal environment: no variables, tools or
  settings from your shell. On Linux the build runs inside its own root filesystem, as an ordinary
  user, so the host distribution doesn't matter.
- **The leaks a plain build has are closed.** For example: the Xcode install path and the builder's
  macOS version written into the app; another Xcode component taking over the Swift toolchain; Rust
  standard-library paths that name your home directory; an object file's timestamp in the Dart
  snapshot's build ID; tools fetched at build time with no lockfile.

## What it doesn't prove

- **Signed releases.** `verify` compares unsigned bundles. A signed release differs from its unsigned
  build only in its signatures, but checking one needs the release's unsigned bundle (or those
  signatures moved onto your build), and the tool doesn't do that yet.
- **That the source is safe.** It proves the binary matches the source, not that the source does
  what it should.
- **The toolchain.** Xcode, Flutter, Rust and Ubuntu's packages are trusted as their publishers ship
  them. They are pinned, so everyone trusts the same ones.
- **The firmware.** The app bundles the release's `firmware.bin`, whose secure-boot signature is
  checked. Reproducing the firmware itself is a separate build (`just build-deterministic`).
- **Every platform.** Only macOS (arm64) and Linux (x86_64 and aarch64) are covered. The macOS build
  is arm64 only, because Xcode 27 can't build a universal app with Flutter 3.38.5.

## Config

All pins live beside the tool. Changing a version means changing its pin; anything that doesn't
match is refused.

| File | Pins |
|---|---|
| `repro.toml` | The build root, the Rust version (it must equal `rust-toolchain.toml`), Flutter (version, commit, Dart SDK and engine downloads, the lockfile for Flutter's own tools in `locks/`), and the code generators built with `cargo install`. |
| `macos.toml` | Xcode's path, build and tree hash; the system Ruby's version; and CocoaPods with its complete set of gems. |
| `linux.toml` | Ubuntu's base image per architecture, the archive snapshot, the packages and their versions, the hash of the installed package set per architecture, and Rust's toolchain per architecture. |

The fixed root is `/var/tmp/frostsnap-repro`. `repro clean` empties it apart from its download store;
`repro clean --downloads` removes everything.
