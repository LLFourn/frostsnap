# repro

`repro` builds the Frostsnap desktop app from a commit so that anyone who rebuilds it gets the same
bytes.

## Why

A wallet app asks for a lot of trust. The source is public, but you install a binary, and nothing
in a normal build lets you check that the binary came from that source. If two people building the
same commit get the same bytes, they don't have to trust the release machine: they can rebuild the
release themselves and compare.

A plain `flutter build` doesn't give you that. The result depends on:
- which Xcode, Rust, Flutter, CocoaPods and system libraries happen to be installed;
- where the checkout lives;
- what is on `PATH`;
- the time;
- whatever the build tools fetch from the network on the day.

`repro` pins all of that and checks every pin, every time. What it can't pin, it names: the host
OS and its own utilities (`/usr/bin/ruby`, `tar`, `plutil` and friends on macOS; Docker on Linux,
where everything else comes from the pinned image).

## Use it

Build the tool once. It is a standalone crate, outside the app's workspace, so it has its own
lockfile:

```sh
cargo build --release --manifest-path tools/repro/Cargo.toml
alias repro=$PWD/tools/repro/target/release/repro
```

**To verify a release on macOS**, check out its tag, get its firmware, and rebuild against the
unsigned bundle it was made from:

```sh
git checkout v0.5.0
repro verify macos --commit v0.5.0 --env prod \
  --firmware firmware.bin --out ~/repro-out \
  --against Frostsnap-unsigned.app
```

`verify` builds from scratch and compares the result with the reference. It exits 0 only if both
bundles have the same paths, each file has the same bytes and permission bits, and each symlink the
same target. Directory metadata, timestamps, owners and extended attributes are not compared.
Otherwise it lists the first entries that differ:

```
~/repro-out/Frostsnap.app and Frostsnap-unsigned.app differ in 1 entries:
  "Contents/Frameworks/App.framework/Versions/A/App" differs: file 0755 1430… vs file 0755 146c…
```

**To make a release build on macOS**, build the commit with the signed firmware:

```sh
repro build macos --commit v0.5.0 --env prod --firmware firmware.bin --out ~/release
```

It writes:
- `~/release/Frostsnap.app`, the unsigned bundle;
- its `manifest` (one line per entry: path, type, and a file's mode and sha256 or a symlink's
  target);
- `build.env`, a record of what went in.

**On Linux**, run the same commands through `linux/run.sh`, which runs them in the pinned container.
Put the firmware and the reference in one work directory; it is mounted at the same path inside the
container:

```sh
tools/repro/linux/run.sh ~/repro -- verify linux --commit v0.5.0 --env prod \
  --firmware ~/repro/firmware.bin --out ~/repro/out --against ~/repro/frostsnap
```

The Linux bundle is `frostsnap/`. `repro build linux` refuses to run on a system whose installed
package set isn't the pinned one, so outside the container it stops before building.

Other commands:

| Command | What it does |
|---|---|
| `repro compare <a> <b> …` | Compare bundles or manifest files. |
| `repro manifest [--hash] <dir>` | Print a tree's manifest, or its hash. |
| `repro xcode-hash <Xcode.app>` | Print an Xcode's tree hash as the pin takes it, to check yours before building. |
| `repro fetch <platform>` | Download and verify every input, without building. |
| `repro clean [--downloads]` | Delete everything the tool made, except (or including) its download store. |

### Requirements

**macOS:**
- the Xcode build named in `repro.toml`, installed at its `path` (`/Applications/Xcode_27.1.app`, where GitHub's `xcode-27` runner image keeps it);
- `/usr/bin/ruby`, which macOS ships;
- about 10 GB of disk.

**Linux:** Docker on x86_64 or aarch64, and about 15 GB of disk. `linux/run.sh` starts the pinned
image, installs every package from the pinned snapshot, builds `repro` there and runs it, as CI
does. On a Mac, `linux/lima.yaml` gives you a VM to run it in.

## What it guarantees

Every input the build downloads or installs is pinned by content, and every pin is checked when it
is used, not just when it was downloaded:

| Input | Pinned by |
|---|---|
| Rust, the Dart SDK, codegen tools, CocoaPods gems | sha256 of each downloaded file |
| Flutter | git commit, checked with `git fsck` |
| Flutter's engine artifacts | hash of the whole unpacked tree, checked before any of it runs |
| Xcode (which nobody can download for you) | hash of the whole installed tree, at a fixed path. Group and other write bits are left out: Apple's xip keeps them and GitHub's image clears them, on identical files. |
| Crates and Dart packages | their lockfiles' checksums, re-checked for anything cached |
| Linux system packages | exact versions of the packages the build names, and the hash of the whole installed set (`dpkg-query -W`), per architecture. The pinned image and archive snapshot produce that set. |
| macOS's system Ruby, which only runs CocoaPods | its version only |

Not pinned, and outside the tool's control: the host OS and its own utilities. On macOS the OS
version is recorded in `build.env`, and the build machine's OS build that Xcode writes into each
`Info.plist` is normalised; on Linux the build runs in the pinned image, and the host kernel is
recorded.

Then the build itself:

- **Starts from nothing but the download store.** Every build deletes its previous tools, source,
  home and caches, and reinstalls them from re-verified downloads. Nothing a previous build left
  behind can leak into the next.
- **Builds the commit, not your checkout.** The source comes from `git archive <commit>`, so local
  edits and stray build products can't get in.
- **Uses fixed paths.** Source, tools and caches all live under `/var/tmp/frostsnap-repro` on every
  machine, because paths end up inside the binaries.
- **Runs in an empty environment.** Each command sees only an allowlisted set of variables, a fixed
  `PATH`, `TZ=UTC`, one locale and `umask 022`. Nothing from your shell gets in.
- **Checks the firmware.** A build verifies the bundled firmware's secure-boot signature against the
  `--env` key, as the release pipeline does. A placeholder needs `--unsigned-firmware`, which only
  `--env dev` accepts and which `build.env` records.

It also closes the ways a normal build of this app differs from machine to machine:

| A plain build… | `repro`… |
|---|---|
| builds Rust with cargokit's `rustup run stable`, whatever "stable" is that day | calls the pinned cargo directly |
| lets Flutter download its Dart SDK and run it unchecked, then resolve its own tools with no lockfile | installs the pinned Dart SDK and builds Flutter's tools under a committed lockfile |
| lets cargokit resolve its build tool's Dart packages with no lockfile | runs it under its committed lockfile, enforced |
| on macOS, lets `xcrun` pick the Command Line Tools SDK over Xcode's | sets `SDKROOT` to the pinned Xcode's SDK |
| on macOS, puts an object file's modification time into the Dart snapshot's build ID | sets `ZERO_AR_DATE` |
| on macOS, writes the builder's macOS build number into every `Info.plist` | normalises it |
| on macOS, writes the Xcode install path into the app | requires the pinned Xcode at one path |
| on macOS, lets an optional Xcode component (GitHub's image has the Metal toolchain) become the Swift toolchain | selects Xcode's default toolchain |
| sizes the `git describe` hash by the clone's object count, so the version compiled into the app differs between clones | uses a fixed abbreviation |
| picks up Homebrew's tools from `PATH` (Homebrew's `rsync` changes a framework's file modes) | allows only the pinned tools and the OS's own |

**Measured, across machines.** One commit was built from clean on GitHub's runners and on local
machines, and every build of each platform had the same manifest:

| Platform | Built on | Manifest hash |
|---|---|---|
| macOS (arm64) | two GitHub `xcode-27` runners (on two different image versions), and this Mac twice | `f16192a770c6a9b7ca894e1f8a66a5ef0d595f4c42287de32cf099225f310bd7` |
| Linux x86_64 | two GitHub `ubuntu-22.04` runners, and two local VMs (x86_64 under Rosetta) | `7c2b82df29079b729caead4e1484ab089a7920db8aaf71c5d2a6a2eb96ada98b` |
| Linux aarch64 | two local VMs with different users, home paths, CPU counts, time zones and locales | `b282f424d8919284fe702f95afc05b5461c37818f729fb73248469eb4e3f7398` |

Getting there closed differences a plain build would have kept:
- GitHub's image has Xcode's optional Metal toolchain, which became the Swift toolchain and changed
  the app's `LC_RPATH`;
- `git describe` sized its hash by the clone's object count, which changed the version string
  compiled into the app;
- Apple's xip and GitHub's image install the same Xcode with different group-write bits.

The checks are covered by unit tests:
- a tampered download, cached crate, Flutter cache or lockfile is rejected;
- a reference inside `--out` is refused;
- an unpinned image tag or package version is rejected.

## Not yet proven

- **Other machines than these.** macOS has been compared across one Mac and GitHub's `xcode-27`
  image, all on macOS 27.0.1 (26A434). Linux has been compared across GitHub's runners and VMs on
  one Mac, all inside the pinned image. A different macOS build, or a Linux host with a different
  kernel or CPU, is still untested.
- **Signed releases.** `verify` compares unsigned bundles. Checking a signed release needs either
  the release's unsigned bundle, or its signatures transplanted onto your build, which isn't built
  yet.
- **Release configuration.** macOS builds are arm64 only, because Xcode 27 can't build a universal
  app with Flutter 3.38.5. `--env prod` with real signed firmware hasn't been run end to end.
- **The tool's own compiler on macOS** is whatever Rust you build it with. It never reaches the
  app, but it does the hashing. On Linux, `run.sh` builds the tool with the pinned Rust tarballs,
  each checked against its sha256.

The CI jobs live in `ci/` and run only when copied into `.github/workflows/` and dispatched.
`linux/lima.yaml` sets up a local VM for Linux builds on a Mac. A Linux build there took 15 to 50
minutes, depending on what else the Mac was doing, natively or under Rosetta alike.

## Config reference

Everything is in `repro.toml`. A download is `{ url, sha256 }`. Changing a version means changing
its pin here; the tool refuses any input that doesn't match.

| Key | Meaning |
|---|---|
| `root` | The fixed build root. It must be the same everywhere, because its path reaches the binaries. |
| `rust.version` | Must equal `rust-toolchain.toml` in the source. |
| `rust.host.<triple>` | The rustc, rust-std, cargo and rustfmt tarballs for that host. |
| `flutter.version`, `flutter.commit`, `flutter.git` | The Flutter release, its commit and its repository. The version must equal `frostsnapp/.fvmrc`. |
| `flutter.dart_sdk.<triple>` | The Dart SDK zip of that Flutter's engine, per host. |
| `flutter.tools_lockfile` | `{ path, sha256 }` of the `flutter_tools` lockfile in `locks/`. |
| `flutter.cache.<platform>` | Tree hash of Flutter's downloaded engine artifacts for that platform. |
| `cargo_tools` | `{ name, version, url, sha256 }` for each build-time tool built with `cargo install --locked` (the FRB codegen and `cargo-expand`). |
| `macos.host`, `macos.archs` | The host triple, and the architectures to build. |
| `macos.xcode` | `{ path, build, tree_sha256 }`: where Xcode must be, its build number, and `repro xcode-hash` of it. |
| `macos.ruby` | `{ path, version }` of the system Ruby that runs CocoaPods. |
| `macos.cocoapods` | The CocoaPods version, and its complete gem closure as downloads. |
| `linux.image` | The container image, by `@sha256:` digest. The architecture is the build machine's own, x86_64 or aarch64. |
| `linux.os` | `{ id, version_id }` from `/etc/os-release`. |
| `linux.apt_snapshot` | A `snapshot.ubuntu.com` timestamp. apt resolves every package and dependency from the archive as it was then. |
| `linux.packages` | Exact version of each apt package the build needs. |
| `linux.installed_sha256.<arch>` | sha256 of every installed package, as `dpkg-query -W -f '${Package} ${Version} ${Architecture}\n'` lists them, for `x86_64` and `aarch64`. |

`patches/cargokit.patch` is the one change the build makes to the source tree. It makes cargokit
call the pinned cargo, and run its build tool under its lockfile.
