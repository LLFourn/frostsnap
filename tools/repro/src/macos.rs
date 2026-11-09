//! macOS: Xcode verified by tree hash at a mandated path (the path lands in
//! the app's LC_RPATH), CocoaPods from a pinned gem set on the system Ruby,
//! and the host build number Xcode writes into every Info.plist normalised.

use crate::app::{self, Build};
use crate::config::{Config, Macos, Xcode};
use crate::env::{self, Env, Layout};
use crate::{manifest, tools};
use anyhow::{Context, Result, bail};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Stdio;

const BUNDLE: &str = "Frostsnap.app";

/// The Xcode pin leaves out group and other write bits: extracting Apple's
/// xip keeps them, while GitHub's runner image clears them, on otherwise
/// identical files. Nothing in the toolchain's output depends on them.
pub const XCODE_MODE_MASK: u32 = 0o7755;

/// Verifies Xcode and installs every pinned tool afresh from the download
/// store, returning the environment the build runs in.
pub fn prepare(config: &Config, layout: &Layout, repo: &Path) -> Result<Env> {
    let m = config.macos()?;
    check_xcode(&m.xcode)?;
    let rust = host_rust(config, repo)?;
    layout.clean()?;
    let mut env = Env::new(layout);
    env.set("DEVELOPER_DIR", developer_dir(&m.xcode));
    // Without SDKROOT, xcrun (and so `cc` in Rust build scripts) prefers the
    // Command Line Tools SDK whenever one is installed, whatever its version.
    let sdk = env::output(
        env.command("xcrun")
            .args(["--sdk", "macosx", "--show-sdk-path"]),
    )?;
    env.set("SDKROOT", sdk);
    // Flutter links App.framework with clang outside Xcode's own link steps,
    // and ld64 hashes the object file's mtime from the debug map into
    // LC_UUID unless this is set.
    env.set("ZERO_AR_DATE", "1");
    // Optional Xcode components can register toolchains of their own; the
    // Metal toolchain on GitHub's image otherwise becomes the Swift toolchain
    // and its path lands in the app's LC_RPATH.
    env.set("TOOLCHAINS", "com.apple.dt.toolchain.XcodeDefault");
    env.prepend_path(rust.sysroot.join("bin"));
    // rust-toolchain.toml installs rust-src, and rustc then writes std's
    // source paths into the binary as paths into this user's toolchain.
    // This puts back the path a toolchain without rust-src would write.
    env.set(
        "RUSTFLAGS",
        format!(
            "--remap-path-prefix={}=/rustc/{}",
            rust.sysroot.join("lib/rustlib/src/rust").display(),
            rust.commit
        ),
    );
    app::cargo_tools(config, layout, &mut env)?;
    let gems = tools::cocoapods(layout, &env, &m.ruby, &m.cocoapods)?;
    env.set("GEM_HOME", &gems)
        .set("GEM_PATH", &gems)
        .prepend_path(gems.join("bin"));
    app::flutter(config, layout, &mut env, "macos", &m.host)?;
    app::check_versions(config, &env)?;
    check_versions(&m, &env)?;
    Ok(env)
}

struct HostRust {
    sysroot: PathBuf,
    commit: String,
}

/// The Rust on the invoking user's PATH, run from the repository so a
/// rustup proxy picks rust-toolchain.toml's version. It must be the pinned
/// version; the build then runs that toolchain's own binaries directly.
fn host_rust(config: &Config, repo: &Path) -> Result<HostRust> {
    let want = &config.rust.version;
    let rustc = |args: &[&str]| {
        std::process::Command::new("rustc")
            .args(args)
            .current_dir(repo)
            .output()
            .ok()
            .filter(|out| out.status.success())
            .map(|out| String::from_utf8_lossy(&out.stdout).trim().to_owned())
    };
    let found = rustc(&["--version"]);
    if !found
        .as_deref()
        .is_some_and(|v| v.starts_with(&format!("rustc {want} ")))
    {
        bail!(
            "Rust {want} is needed to build this reproducibly (found {}); rustup toolchain install {want}",
            found.as_deref().unwrap_or("no rustc on PATH")
        );
    }
    let verbose = rustc(&["-vV"]).context("running rustc -vV")?;
    let commit = verbose
        .lines()
        .find_map(|line| line.strip_prefix("commit-hash: "))
        .context("rustc -vV has no commit-hash")?
        .to_owned();
    let sysroot =
        PathBuf::from(rustc(&["--print", "sysroot"]).context("running rustc --print sysroot")?);
    Ok(HostRust { sysroot, commit })
}

pub fn build(config: &Config, layout: &Layout, env: &Env, repo: &Path, b: &Build) -> Result<()> {
    let m = config.macos()?;
    let app::Generated {
        app_dir,
        mut env,
        firmware,
    } = app::generate(config, layout, env, repo, b)?;
    env.set("FLUTTER_XCODE_ARCHS", m.archs.join(" "))
        .set("FLUTTER_XCODE_CODE_SIGNING_ALLOWED", "NO")
        .set("FROSTSNAP_ENV", b.env)
        .set("BUNDLE_FIRMWARE", "1");
    env::run(
        env.command("flutter")
            .args(["build", "macos", "--release"])
            .args(app::dart_defines(b))
            .current_dir(&app_dir),
    )?;

    let app = bundle(b.out);
    fs::create_dir_all(b.out)?;
    if app.exists() {
        fs::remove_dir_all(&app)?;
    }
    env::run(
        env.command("ditto")
            .arg(
                app_dir
                    .join("build/macos/Build/Products/Release")
                    .join(BUNDLE),
            )
            .arg(&app),
    )?;
    normalise_build_machine(&env, &app)?;
    let os_build = env::output(env.command("sw_vers").arg("-buildVersion"))?;
    let os_version = env::output(env.command("sw_vers").arg("-productVersion"))?;
    app::write_record(
        b,
        &app,
        &firmware,
        &format!("os_version={os_version}\nos_build={os_build}\n"),
    )
}

pub fn bundle(out: &Path) -> PathBuf {
    out.join(BUNDLE)
}

fn developer_dir(x: &Xcode) -> PathBuf {
    x.path.join("Contents/Developer")
}

fn check_xcode(x: &Xcode) -> Result<()> {
    if !developer_dir(x).is_dir() {
        bail!(
            "Xcode must be installed at {}: that path is embedded in the app",
            x.path.display()
        );
    }
    eprintln!("hashing {}", x.path.display());
    let got = xcode_hash(&x.path)?;
    if got != x.tree_sha256 {
        bail!(
            "{} has tree hash {got}, pinned {} (Xcode {})",
            x.path.display(),
            x.tree_sha256,
            x.build
        );
    }
    Ok(())
}

/// The hash `macos.xcode.tree_sha256` pins.
pub fn xcode_hash(xcode: &Path) -> Result<String> {
    Ok(manifest::hash(&manifest::of_tree_with(
        xcode,
        &[],
        XCODE_MODE_MASK,
    )?))
}

fn check_versions(m: &Macos, env: &Env) -> Result<()> {
    let developer = developer_dir(&m.xcode);
    let sdk = env::output(env.command("xcrun").arg("--show-sdk-path"))?;
    if !Path::new(&sdk).starts_with(&developer) {
        bail!("SDK {sdk} is not inside {}", developer.display());
    }
    let xcode = env::output(env.command("xcodebuild").arg("-version"))?;
    if !xcode
        .lines()
        .any(|l| l == format!("Build version {}", m.xcode.build))
    {
        bail!("Xcode reports {xcode:?}, pinned build {}", m.xcode.build);
    }
    let pod = env::output(env.command("pod").arg("--version"))?;
    if pod.lines().last() != Some(m.cocoapods.version.as_str()) {
        bail!("CocoaPods {pod}, pinned {}", m.cocoapods.version);
    }
    Ok(())
}

/// The host's macOS build is not an input that can be pinned across machines,
/// so it is replaced before signing.
fn normalise_build_machine(env: &Env, app: &Path) -> Result<()> {
    for plist in info_plists(app)? {
        let has_key = env
            .command("plutil")
            .args(["-extract", "BuildMachineOSBuild", "raw"])
            .arg(&plist)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()?
            .success();
        if has_key {
            env::run(
                env.command("plutil")
                    .args(["-replace", "BuildMachineOSBuild", "-string", "normalized"])
                    .arg(&plist),
            )?;
        }
    }
    Ok(())
}

fn info_plists(dir: &Path) -> Result<Vec<PathBuf>> {
    let mut found = Vec::new();
    for entry in fs::read_dir(dir)? {
        let entry = entry?;
        let kind = entry.file_type()?;
        if kind.is_dir() {
            found.extend(info_plists(&entry.path())?);
        } else if kind.is_file() && entry.file_name() == "Info.plist" {
            found.push(entry.path());
        }
    }
    Ok(found)
}
