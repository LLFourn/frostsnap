//! Installs each pinned toolchain at its fixed path under the root. Installs
//! are never reused: every build makes them again from the download store,
//! whose contents are re-verified on each use, so nothing installed by an
//! earlier build can reach a later one.

use crate::config::{CocoaPods, Crate, Download, Flutter, Ruby};
use crate::env::{self, Env, Layout};
use crate::{manifest, store};
use anyhow::{Context, Result, bail};
use std::fs;
use std::path::{Path, PathBuf};

/// Files Flutter rewrites on every run, or builds itself from the pinned
/// checkout rather than downloading.
const FLUTTER_CACHE_UNPINNED: &[&str] = &[
    "lockfile",
    "downloads",
    "flutter_tools.snapshot",
    "flutter_tools.stamp",
];

const PLATFORMS: &[&str] = &[
    "android", "ios", "web", "linux", "windows", "macos", "fuchsia",
];

pub fn rust(layout: &Layout, env: &Env, components: &[Download]) -> Result<PathBuf> {
    install(layout, "rust", |dir| {
        for d in components {
            let file = store::fetch(&layout.downloads(), d)?;
            let unpack = layout.tmp().join("rust-unpack");
            env::fresh_dir(&unpack)?;
            env::run(
                env.command("tar")
                    .arg("-xJf")
                    .arg(&file)
                    .arg("-C")
                    .arg(&unpack),
            )?;
            let top = only_child(&unpack)?;
            env::run(
                env.command("sh")
                    .arg(top.join("install.sh"))
                    .arg(format!("--prefix={}", dir.display()))
                    .arg("--disable-ldconfig"),
            )?;
        }
        Ok(())
    })
    .map(|dir| dir.join("bin"))
}

/// `tools_lock` is the pinned `flutter_tools` lockfile's contents, and
/// `target` a Flutter target platform such as `macos` or `linux-arm64`.
pub fn flutter(
    layout: &Layout,
    env: &Env,
    f: &Flutter,
    tools_lock: &[u8],
    target: &str,
    host: &str,
) -> Result<PathBuf> {
    let platform = target.split('-').next().expect("split yields one item");
    let pinned_cache = f.cache.get(target);
    install(layout, "flutter", |dir| {
        let mirror = flutter_mirror(layout, env, f)?;
        env::run(
            env.command("git")
                .args(["clone", "--quiet", "--branch", &f.version])
                .arg(&mirror)
                .arg(dir),
        )?;
        let head = env::output(
            env.command("git")
                .arg("-C")
                .arg(dir)
                .args(["rev-parse", "HEAD"]),
        )?;
        if head != f.commit {
            bail!(
                "Flutter tag {} is commit {head}, pinned {}",
                f.version,
                f.commit
            );
        }
        // Flutter reads its version and channel from origin.
        env::run(
            env.command("git")
                .arg("-C")
                .arg(dir)
                .args(["remote", "set-url", "origin", &f.git]),
        )?;

        let cache = dir.join("bin/cache");
        let archive = pinned_cache.map(|pin| {
            layout
                .downloads()
                .join("flutter-cache")
                .join(format!("{pin}.tar"))
        });
        let dart_sdk = f
            .dart_sdk
            .get(host)
            .with_context(|| format!("no flutter.dart_sdk pin for {host}"))?;
        install_dart_sdk(layout, env, dir, dart_sdk)?;
        let restored = match (&archive, pinned_cache) {
            (Some(archive), Some(pin)) if archive.exists() => {
                restore_flutter_cache(env, archive, &cache, pin)?;
                true
            }
            _ => false,
        };
        bootstrap_flutter_tools(env, dir, &f.commit, tools_lock)?;
        let mut env = env.clone();
        env.prepend_path(dir.join("bin"));
        let flags = PLATFORMS.iter().map(|p| {
            if *p == platform {
                format!("--{p}")
            } else {
                format!("--no-{p}")
            }
        });
        env::run(env.command("flutter").arg("precache").args(flags))?;
        let (Some(archive), Some(pin)) = (archive, pinned_cache) else {
            bail!(
                "no flutter.cache pin for {target}; this download's tree hash is {}",
                flutter_cache_hash(&cache)?
            );
        };
        check_flutter_cache(&cache, pin)?;
        if !restored {
            fs::create_dir_all(archive.parent().expect("has parent"))?;
            let partial = archive.with_extension("partial");
            let excludes = FLUTTER_CACHE_UNPINNED
                .iter()
                .map(|p| format!("--exclude=./{p}"));
            env::run(
                env.command("tar")
                    .arg("-cf")
                    .arg(&partial)
                    .args(excludes)
                    .arg("-C")
                    .arg(&cache)
                    .arg("."),
            )?;
            fs::rename(partial, archive)?;
        }
        Ok(())
    })
    .map(|dir| dir.join("bin"))
}

/// What `bin/internal/update_dart_sdk.sh` does, from the pinned zip.
fn install_dart_sdk(layout: &Layout, env: &Env, flutter: &Path, zip: &Download) -> Result<()> {
    let file = store::fetch(&layout.downloads(), zip)?;
    let cache = flutter.join("bin/cache");
    fs::create_dir_all(&cache)?;
    env::run(
        env.command("unzip")
            .args(["-o", "-q"])
            .arg(&file)
            .arg("-d")
            .arg(&cache),
    )?;
    let sdk = cache.join("dart-sdk");
    env::run(
        env.command("find")
            .arg(&sdk)
            .args(["-type", "d", "-exec", "chmod", "755", "{}", ";"]),
    )?;
    // `-perm -100`, where Flutter's script has `+100` for BSD find and `/u+x`
    // for GNU find: the one spelling both accept.
    env::run(env.command("find").arg(&sdk).args([
        "-type", "f", "-perm", "-100", "-exec", "chmod", "a+x,a+r", "{}", ";",
    ]))?;
    let engine = fs::read_to_string(flutter.join("bin/internal/engine.version"))?;
    fs::write(
        cache.join("engine-dart-sdk.stamp"),
        format!("{}\n", engine.trim()),
    )?;
    Ok(())
}

/// What `bin/internal/shared.sh` does to build the tool's snapshot, but with
/// `pub get --enforce-lockfile` against the pinned lockfile in place of
/// `pub upgrade`. The stamp it writes is the one shared.sh checks, so Flutter
/// then uses this snapshot and never runs its own upgrade.
fn bootstrap_flutter_tools(env: &Env, flutter: &Path, commit: &str, lock: &[u8]) -> Result<()> {
    // Writes bin/cache/engine.stamp, which the tool's first run reads; a
    // restored cache already has it, a fresh one doesn't.
    env::run(&mut env.command(flutter.join("bin/internal/update_engine_version.sh")))?;
    // shared.sh creates this whenever it builds the tool, and it is part of
    // the pinned cache.
    fs::write(flutter.join("bin/cache/.dartignore"), "")?;
    let tools = flutter.join("packages/flutter_tools");
    let dart = flutter.join("bin/cache/dart-sdk/bin/dart");
    fs::write(tools.join("pubspec.lock"), lock)?;
    env::run(
        env.command(&dart)
            .args(["pub", "get", "--enforce-lockfile", "--suppress-analytics"])
            .current_dir(&tools),
    )?;
    let snapshot = flutter.join("bin/cache/flutter_tools.snapshot");
    env::run(
        env.command(&dart)
            .arg("--verbosity=error")
            .arg(format!("--snapshot={}", snapshot.display()))
            .arg("--snapshot-kind=app-jit")
            .arg(format!(
                "--packages={}",
                tools.join(".dart_tool/package_config.json").display()
            ))
            .arg("--no-enable-mirrors")
            .arg(tools.join("bin/flutter_tools.dart"))
            .stdout(std::process::Stdio::null()),
    )?;
    fs::write(
        flutter.join("bin/cache/flutter_tools.stamp"),
        format!("{commit}:\n"),
    )?;
    Ok(())
}

/// Unpacks a stored Flutter cache and checks it before anything in it runs.
fn restore_flutter_cache(env: &Env, archive: &Path, cache: &Path, pinned: &str) -> Result<()> {
    fs::create_dir_all(cache)?;
    env::run(
        env.command("tar")
            .arg("-xpf")
            .arg(archive)
            .arg("-C")
            .arg(cache),
    )?;
    check_flutter_cache(cache, pinned).with_context(|| {
        format!(
            "restoring {}; delete it to download again",
            archive.display()
        )
    })
}

fn flutter_cache_hash(cache: &Path) -> Result<String> {
    Ok(manifest::hash(&manifest::of_tree_skipping(
        cache,
        FLUTTER_CACHE_UNPINNED,
    )?))
}

fn check_flutter_cache(cache: &Path, pinned: &str) -> Result<()> {
    let got = flutter_cache_hash(cache)?;
    if got != pinned {
        bail!("Flutter's cache has tree hash {got}, pinned {pinned}");
    }
    Ok(())
}

/// A shallow bare clone of the pinned tag, kept in the download store and
/// checked with `git fsck` each time it is used.
fn flutter_mirror(layout: &Layout, env: &Env, f: &Flutter) -> Result<PathBuf> {
    let mirror = layout
        .downloads()
        .join("git")
        .join(format!("flutter-{}.git", f.commit));
    if !mirror.exists() {
        let partial = mirror.with_extension("partial");
        if partial.exists() {
            fs::remove_dir_all(&partial)?;
        }
        env::run(
            env.command("git")
                .args([
                    "clone", "--quiet", "--bare", "--depth", "1", "--branch", &f.version, &f.git,
                ])
                .arg(&partial),
        )?;
        fs::rename(&partial, &mirror)?;
    }
    env::run(env.command("git").arg("-C").arg(&mirror).args([
        "fsck",
        "--strict",
        "--no-dangling",
        "--no-progress",
    ]))?;
    Ok(mirror)
}

/// `env` must already have the pinned Rust on its PATH.
pub fn cargo_tool(layout: &Layout, env: &Env, c: &Crate) -> Result<PathBuf> {
    install(layout, &c.name, |dir| {
        let file = store::fetch(&layout.downloads(), &c.download)?;
        let unpack = layout.tmp().join(format!("{}-src", c.name));
        env::fresh_dir(&unpack)?;
        env::run(
            env.command("tar")
                .arg("-xzf")
                .arg(&file)
                .arg("-C")
                .arg(&unpack),
        )?;
        let src = unpack.join(format!("{}-{}", c.name, c.version));
        store::verify_cargo_cache(env, &layout.cargo_home(), &src.join("Cargo.lock"))?;
        env::run(
            env.command("cargo")
                .args(["install", "--locked", "--quiet", "--path"])
                .arg(src)
                .arg("--root")
                .arg(dir),
        )
    })
    .map(|dir| dir.join("bin"))
}

/// Returns the GEM_HOME holding `pod`.
pub fn cocoapods(layout: &Layout, env: &Env, ruby: &Ruby, pods: &CocoaPods) -> Result<PathBuf> {
    let got = env::output(env.command(&ruby.path).args(["-e", "print RUBY_VERSION"]))?;
    if got != ruby.version {
        bail!(
            "{} is Ruby {got}, pinned {}",
            ruby.path.display(),
            ruby.version
        );
    }
    install(layout, "gems", |dir| {
        let staged = layout.tmp().join("gems");
        env::fresh_dir(&staged)?;
        let mut files = Vec::new();
        for d in &pods.gems {
            let file = staged.join(store::file_name(d)?);
            std::os::unix::fs::symlink(store::fetch(&layout.downloads(), d)?, &file)?;
            files.push(file);
        }
        env::run(
            env.command(&ruby.path)
                .args([
                    "-S",
                    "gem",
                    "install",
                    "--quiet",
                    "--no-document",
                    "--local",
                    "--ignore-dependencies",
                    "--install-dir",
                ])
                .arg(dir)
                .args(files),
        )
    })
}

fn install(
    layout: &Layout,
    name: &str,
    install: impl FnOnce(&Path) -> Result<()>,
) -> Result<PathBuf> {
    eprintln!("installing {name}");
    let dir = layout.tool(name);
    env::fresh_dir(&dir)?;
    env::fresh_dir(&layout.tmp())?;
    install(&dir).with_context(|| format!("installing {name}"))?;
    Ok(dir)
}

fn only_child(dir: &Path) -> Result<PathBuf> {
    let mut entries = fs::read_dir(dir)?.collect::<Result<Vec<_>, _>>()?;
    match entries.len() {
        1 => Ok(entries.remove(0).path()),
        n => bail!("{} has {n} entries, expected one", dir.display()),
    }
}

#[cfg(test)]
mod test {
    use super::*;

    #[test]
    fn every_hosted_flutter_tools_package_has_a_content_hash() {
        let config =
            crate::config::Config::load(&Path::new(env!("CARGO_MANIFEST_DIR")).join("repro.toml"))
                .unwrap();
        let lock =
            String::from_utf8(config.read_local(&config.flutter.tools_lockfile).unwrap()).unwrap();
        let hosted = lock.matches("source: hosted").count();
        let hashed = lock.matches("      sha256: ").count();
        assert!(hosted > 0);
        assert_eq!(hosted, hashed);
    }

    #[test]
    fn a_changed_stored_flutter_cache_is_rejected_before_use() {
        let root =
            std::env::temp_dir().join(format!("repro-test-{}-flutter-cache", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        let env = Env::new(&Layout { root: root.clone() });
        let original = root.join("original");
        fs::create_dir_all(original.join("dart-sdk/bin")).unwrap();
        fs::write(original.join("dart-sdk/bin/dart"), b"pinned dart").unwrap();
        fs::write(original.join("dart-sdk/version"), b"3.10.4").unwrap();
        let pinned =
            manifest::hash(&manifest::of_tree_skipping(&original, FLUTTER_CACHE_UNPINNED).unwrap());

        let archive = root.join("cache.tar");
        env::run(
            env.command("tar")
                .arg("-cf")
                .arg(&archive)
                .arg("-C")
                .arg(&original)
                .arg("."),
        )
        .unwrap();
        restore_flutter_cache(&env, &archive, &root.join("good"), &pinned).unwrap();

        fs::write(original.join("dart-sdk/bin/dart"), b"other dart").unwrap();
        env::run(
            env.command("tar")
                .arg("-cf")
                .arg(&archive)
                .arg("-C")
                .arg(&original)
                .arg("."),
        )
        .unwrap();
        assert!(restore_flutter_cache(&env, &archive, &root.join("bad"), &pinned).is_err());
        fs::remove_dir_all(&root).unwrap();
    }
}
