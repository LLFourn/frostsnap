//! The steps every platform shares: the cargo tools, Flutter, the source tree
//! at the fixed path, the firmware, the locked dependencies and the generated
//! code. A platform module provides Rust and its own toolchain, and runs
//! `flutter build`.

use crate::config::Config;
use crate::env::{self, Env, Layout};
use crate::{manifest, store, tools};
use anyhow::{Context, Result, bail};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Stdio;

pub struct Build<'a> {
    pub commit: &'a str,
    pub version: &'a str,
    pub env: &'a str,
    pub firmware: &'a Path,
    pub out: &'a Path,
}

/// The source tree ready for `flutter build`, and the environment to run it
/// in. `firmware` is where the firmware went; `flutter build` needs
/// `BUNDLE_FIRMWARE=1` to bundle it.
pub struct Generated {
    pub app_dir: PathBuf,
    pub env: Env,
    pub firmware: PathBuf,
}

/// Builds the cargo tools afresh from the store. `env` must already have the
/// build's Rust on its PATH.
pub fn cargo_tools(config: &Config, layout: &Layout, env: &mut Env) -> Result<()> {
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
    let firmware = place_firmware(&src, b)?;

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
        "commit={}\nversion={}\nenv={}\nfirmware_sha256={}\n{host}",
        b.commit,
        b.version,
        b.env,
        manifest::sha256_file(firmware)?,
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

/// Firmware goes where the release build puts it, so that with
/// `BUNDLE_FIRMWARE=1` `build.rs` checks its secure-boot signature against
/// `b.env`'s key, as it does for a release.
fn place_firmware(src: &Path, b: &Build) -> Result<PathBuf> {
    let dest = src.join(format!(
        "target/riscv32imc-unknown-none-elf/release/{}-frontier.bin",
        b.env
    ));
    fs::create_dir_all(dest.parent().expect("has parent"))?;
    fs::copy(b.firmware, &dest).with_context(|| format!("copying {}", b.firmware.display()))?;
    Ok(dest)
}
