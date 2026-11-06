//! The steps every platform shares: the pinned toolchain, the source tree at
//! the fixed path, its patch, the firmware, the locked dependencies and the
//! generated code. A platform module adds its own toolchain on top and runs
//! `flutter build`.

use crate::config::Config;
use crate::env::{self, Env, Layout};
use crate::{manifest, store, tools};
use anyhow::{Context, Result, bail};
use std::ffi::OsString;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::Stdio;

const CARGOKIT_PATCH: &str = include_str!("../patches/cargokit.patch");

pub struct Build<'a> {
    pub commit: &'a str,
    pub version: &'a str,
    pub env: &'a str,
    pub firmware: &'a Path,
    pub unsigned_firmware: bool,
    pub out: &'a Path,
}

/// The source tree ready for `flutter build`, and the environment to run it
/// in. `firmware` is where the firmware went, and `bundle_firmware` the value
/// `BUNDLE_FIRMWARE` must have.
pub struct Generated {
    pub app_dir: PathBuf,
    pub env: Env,
    pub firmware: PathBuf,
    pub bundle_firmware: OsString,
}

/// Installs Rust and the cargo tools for `host` afresh from the store.
pub fn toolchain(config: &Config, layout: &Layout, env: &mut Env, host: &str) -> Result<()> {
    let components = config
        .rust
        .host
        .get(host)
        .with_context(|| format!("no rust.host pin for {host}"))?;
    env.prepend_path(tools::rust(layout, env, components)?);
    for tool in &config.cargo_tools {
        env.prepend_path(tools::cargo_tool(layout, env, tool)?);
    }
    Ok(())
}

/// Installs Flutter afresh from the store, with the engine artifacts for
/// `target`: `macos`, `linux-x64` or `linux-arm64`.
pub fn flutter(
    config: &Config,
    layout: &Layout,
    env: &mut Env,
    target: &str,
    host: &str,
) -> Result<()> {
    let lock = config.read_local(&config.flutter.tools_lockfile)?;
    env.prepend_path(tools::flutter(
        layout,
        env,
        &config.flutter,
        &lock,
        target,
        host,
    )?);
    Ok(())
}

pub fn check_versions(config: &Config, env: &Env) -> Result<()> {
    let rustc = env::output(env.command("rustc").arg("-V"))?;
    if !rustc.starts_with(&format!("rustc {} ", config.rust.version)) {
        bail!("{rustc}, pinned {}", config.rust.version);
    }
    let flutter: serde_json::Value = serde_json::from_str(&env::output(
        env.command("flutter").args(["--version", "--machine"]),
    )?)?;
    if flutter["frameworkVersion"] != config.flutter.version.as_str() {
        bail!(
            "Flutter {}, pinned {}",
            flutter["frameworkVersion"],
            config.flutter.version
        );
    }
    Ok(())
}

pub fn generate(
    config: &Config,
    layout: &Layout,
    env: &Env,
    repo: &Path,
    b: &Build,
) -> Result<Generated> {
    let src = layout.src();
    for dir in [&src, &layout.home(), &layout.tmp()] {
        env::fresh_dir(dir)?;
    }
    export_source(env, repo, b.commit, &src)?;
    check_source_pins(config, &src)?;
    let mut patch = env
        .command("patch")
        .args(["-s", "-p1", "-d"])
        .arg(&src)
        .stdin(Stdio::piped())
        .spawn()?;
    patch
        .stdin
        .take()
        .expect("piped")
        .write_all(CARGOKIT_PATCH.as_bytes())?;
    if !patch.wait()?.success() {
        bail!("cargokit patch no longer applies");
    }
    let (firmware, bundle_firmware) = place_firmware(layout, &src, b)?;

    let app_dir = src.join("frostsnapp");
    let mut env = env.clone();
    store::verify_cargo_cache(&env, &layout.cargo_home(), &src.join("Cargo.lock"))?;
    env::run(
        env.command("cargo")
            .args(["fetch", "--locked"])
            .current_dir(&src),
    )?;
    env::run(
        env.command("flutter")
            .args(["pub", "get", "--enforce-lockfile"])
            .current_dir(&app_dir),
    )?;
    env.set("CARGO_NET_OFFLINE", "true");
    env::run(
        env.command("flutter_rust_bridge_codegen")
            .arg("generate")
            .current_dir(&app_dir),
    )?;
    env::run(
        env.command("dart")
            .args([
                "run",
                "build_runner",
                "build",
                "--delete-conflicting-outputs",
            ])
            .current_dir(&app_dir),
    )?;
    Ok(Generated {
        app_dir,
        env,
        firmware,
        bundle_firmware,
    })
}

/// The `flutter build` arguments every platform passes.
pub fn dart_defines(b: &Build) -> [String; 2] {
    [
        format!("--dart-define=BUILD_COMMIT={}", b.commit),
        format!("--dart-define=BUILD_VERSION={}", b.version),
    ]
}

/// Writes `tree`'s manifest and the build record beside it. `host` is the
/// platform's own `key=value` lines describing the build machine.
pub fn write_record(b: &Build, tree: &Path, firmware: &Path, host: &str) -> Result<()> {
    fs::write(b.out.join("manifest"), manifest::of_tree(tree)?)?;
    let record = format!(
        "commit={}\nversion={}\nenv={}\nfirmware_sha256={}\nfirmware_signature={}\n{host}",
        b.commit,
        b.version,
        b.env,
        manifest::sha256_file(firmware)?,
        if b.unsigned_firmware {
            "unchecked"
        } else {
            "checked"
        },
    );
    fs::write(b.out.join("build.env"), record)?;
    eprintln!("built {}", tree.display());
    Ok(())
}

fn export_source(env: &Env, repo: &Path, commit: &str, dest: &Path) -> Result<()> {
    let mut archive = env
        .command("git")
        .arg("-C")
        .arg(repo)
        .args(["archive", commit])
        .stdout(Stdio::piped())
        .spawn()?;
    env::run(
        env.command("tar")
            .arg("-x")
            .arg("-C")
            .arg(dest)
            .stdin(archive.stdout.take().expect("piped")),
    )?;
    if !archive.wait()?.success() {
        bail!("git archive {commit} failed");
    }
    Ok(())
}

/// The config pins tools by version too, so the source must agree with it.
fn check_source_pins(config: &Config, src: &Path) -> Result<()> {
    let toolchain: toml::Value =
        toml::from_str(&fs::read_to_string(src.join("rust-toolchain.toml"))?)?;
    let channel = toolchain["toolchain"]["channel"].as_str();
    if channel != Some(config.rust.version.as_str()) {
        bail!(
            "rust-toolchain.toml wants {channel:?}, config pins {}",
            config.rust.version
        );
    }
    let fvm: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(src.join("frostsnapp/.fvmrc"))?)?;
    if fvm["flutter"] != config.flutter.version.as_str() {
        bail!(
            ".fvmrc wants Flutter {}, config pins {}",
            fvm["flutter"],
            config.flutter.version
        );
    }
    Ok(())
}

/// Firmware goes where the release build puts it, with `BUNDLE_FIRMWARE=1`,
/// so `build.rs` checks its secure-boot signature against `b.env`'s key.
/// `build.rs` skips that check for an explicit path, so only
/// `--unsigned-firmware` uses one.
fn place_firmware(layout: &Layout, src: &Path, b: &Build) -> Result<(PathBuf, OsString)> {
    let (dest, bundle) = if b.unsigned_firmware {
        (layout.firmware(), layout.firmware().into_os_string())
    } else {
        let dest = src.join(format!(
            "target/riscv32imc-unknown-none-elf/release/{}-frontier.bin",
            b.env
        ));
        (dest, OsString::from("1"))
    };
    fs::create_dir_all(dest.parent().expect("has parent"))?;
    fs::copy(b.firmware, &dest).with_context(|| format!("copying {}", b.firmware.display()))?;
    Ok((dest, bundle))
}
