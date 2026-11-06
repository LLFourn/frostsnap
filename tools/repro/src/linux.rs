//! Linux: the build runs in a pinned Ubuntu image, with every apt package
//! taken from one snapshot of the Ubuntu archive, so the compilers, GTK and
//! libc headers are the same everywhere. The image digest and snapshot are
//! applied by whoever starts the build (the CI job does); the tool refuses to
//! build unless the OS and every pinned package version match.

use crate::app::{self, Build};
use crate::config::{Config, Linux, Os};
use crate::env::{self, Env, Layout};
use anyhow::{Context, Result, bail};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};

const BUNDLE: &str = "frostsnap";

/// The build machine's Rust host triple and Flutter architecture name.
fn arch() -> Result<(&'static str, &'static str)> {
    match std::env::consts::ARCH {
        "x86_64" => Ok(("x86_64-unknown-linux-gnu", "x64")),
        "aarch64" => Ok(("aarch64-unknown-linux-gnu", "arm64")),
        other => bail!("no Linux build for {other}"),
    }
}

pub fn prepare(config: &Config, layout: &Layout) -> Result<Env> {
    let l = &config.linux;
    check_system(l)?;
    layout.clean()?;
    let (host, flutter_arch) = arch()?;
    let mut env = Env::new(layout);
    // The image has no locales installed; C.UTF-8 is the one glibc always has.
    env.set("LANG", "C.UTF-8").set("LC_ALL", "C.UTF-8");
    app::toolchain(config, layout, &mut env, host)?;
    app::flutter(
        config,
        layout,
        &mut env,
        &format!("linux-{flutter_arch}"),
        host,
    )?;
    app::check_versions(config, &env)?;
    Ok(env)
}

pub fn build(config: &Config, layout: &Layout, env: &Env, repo: &Path, b: &Build) -> Result<()> {
    let app::Generated {
        app_dir,
        mut env,
        firmware,
        bundle_firmware,
    } = app::generate(config, layout, env, repo, b)?;
    let commit_time = env::output(env.command("git").arg("-C").arg(repo).args([
        "log",
        "-1",
        "--format=%ct",
        b.commit,
    ]))?;
    // The convention reproducible-builds tools honour for "now"; set so that
    // nothing in the system toolchain stamps the build time.
    env.set("SOURCE_DATE_EPOCH", commit_time)
        .set("FROSTSNAP_ENV", b.env)
        .set("BUNDLE_FIRMWARE", bundle_firmware);
    let (_, flutter_arch) = arch()?;
    env::run(
        env.command("flutter")
            .args(["build", "linux", "--release", "--target-platform"])
            .arg(format!("linux-{flutter_arch}"))
            .args(app::dart_defines(b))
            .current_dir(&app_dir),
    )?;

    let out = bundle(b.out);
    fs::create_dir_all(b.out)?;
    if out.exists() {
        fs::remove_dir_all(&out)?;
    }
    env::run(
        env.command("cp")
            .arg("-a")
            .arg(app_dir.join(format!("build/linux/{flutter_arch}/release/bundle")))
            .arg(&out),
    )?;
    let os = parse_os_release(&fs::read_to_string("/etc/os-release")?);
    let kernel = env::output(env.command("uname").arg("-r"))?;
    let installed_sha256 = installed_set_sha256()?;
    app::write_record(
        b,
        &out,
        &firmware,
        &format!(
            "os={}\nkernel={kernel}\ndpkg_sha256={installed_sha256}\n",
            os.get("PRETTY_NAME")
                .map(String::as_str)
                .unwrap_or("unknown"),
        ),
    )
}

pub fn bundle(out: &Path) -> PathBuf {
    out.join(BUNDLE)
}

fn check_system(l: &Linux) -> Result<()> {
    let text = fs::read_to_string("/etc/os-release").context("reading /etc/os-release")?;
    check_os(&parse_os_release(&text), &l.os)?;
    let out = std::process::Command::new("dpkg-query")
        .args([
            "-W",
            "-f",
            "${Package}\\t${db:Status-Abbrev}\\t${Version}\\n",
        ])
        .args(l.packages.keys())
        .output()
        .context("running dpkg-query")?;
    let wrong = mismatches(&l.packages, &installed(&String::from_utf8(out.stdout)?));
    if !wrong.is_empty() {
        bail!(
            "system packages differ from the pins (tools/repro/linux/run.sh installs them):\n  {}",
            wrong.join("\n  ")
        );
    }
    check_installed_set(&installed_set_sha256()?, l, std::env::consts::ARCH)
}

/// The packages above are the ones the build names, but every installed
/// package (libc, GTK's own dependencies) can shape the app, so the whole set
/// is pinned too. It is what the pinned image and snapshot install.
fn check_installed_set(got: &str, l: &Linux, arch: &str) -> Result<()> {
    let pinned = l.installed_sha256.get(arch).with_context(|| {
        format!("no linux.installed_sha256 pin for {arch}; this system's is {got}")
    })?;
    if got != pinned {
        bail!(
            "the installed package set has hash {got}, pinned {pinned} for {arch}; build in the pinned image (tools/repro/linux/run.sh)"
        );
    }
    Ok(())
}

/// sha256 of `dpkg-query -W`'s full listing: every installed package, with
/// its version and architecture.
fn installed_set_sha256() -> Result<String> {
    let out = std::process::Command::new("dpkg-query")
        .args(["-W", "-f", "${Package} ${Version} ${Architecture}\\n"])
        .output()
        .context("running dpkg-query")?;
    if !out.status.success() {
        bail!(
            "dpkg-query failed: {}",
            String::from_utf8_lossy(&out.stderr)
        );
    }
    Ok(format!(
        "{:x}",
        Sha256::digest(String::from_utf8(out.stdout)?.trim().as_bytes())
    ))
}

fn check_os(os_release: &BTreeMap<String, String>, pinned: &Os) -> Result<()> {
    let (id, version) = (os_release.get("ID"), os_release.get("VERSION_ID"));
    if id != Some(&pinned.id) || version != Some(&pinned.version_id) {
        bail!(
            "this is {} {}, pinned {} {}",
            id.map(String::as_str).unwrap_or("?"),
            version.map(String::as_str).unwrap_or("?"),
            pinned.id,
            pinned.version_id
        );
    }
    Ok(())
}

fn parse_os_release(text: &str) -> BTreeMap<String, String> {
    text.lines()
        .filter_map(|line| line.split_once('='))
        .map(|(k, v)| (k.trim().to_owned(), v.trim().trim_matches('"').to_owned()))
        .collect()
}

/// Installed versions from `dpkg-query -W -f '${Package}\t${db:Status-Abbrev}\t${Version}\n'`,
/// keeping only packages that are actually installed.
fn installed(dpkg: &str) -> BTreeMap<String, String> {
    dpkg.lines()
        .filter_map(|line| {
            let mut fields = line.split('\t');
            let (name, status, version) = (fields.next()?, fields.next()?, fields.next()?);
            status
                .starts_with("ii")
                .then(|| (name.to_owned(), version.to_owned()))
        })
        .collect()
}

fn mismatches(
    pinned: &BTreeMap<String, String>,
    installed: &BTreeMap<String, String>,
) -> Vec<String> {
    pinned
        .iter()
        .filter_map(|(name, want)| match installed.get(name) {
            Some(got) if got == want => None,
            Some(got) => Some(format!("{name} is {got}, pinned {want}")),
            None => Some(format!("{name} is not installed, pinned {want}")),
        })
        .collect()
}

#[cfg(test)]
mod test {
    use super::*;

    const NOBLE: &str = "PRETTY_NAME=\"Ubuntu 24.04.3 LTS\"\nNAME=\"Ubuntu\"\nVERSION_ID=\"24.04\"\nID=ubuntu\nID_LIKE=debian\n";

    fn pins() -> BTreeMap<String, String> {
        [
            ("clang", "1:18.0-59~exp2"),
            ("cmake", "3.28.3-1build7"),
            ("libgtk-3-dev", "3.24.41-4ubuntu1.3"),
        ]
        .into_iter()
        .map(|(k, v)| (k.to_owned(), v.to_owned()))
        .collect()
    }

    #[test]
    fn os_must_match_the_pin() {
        let os = parse_os_release(NOBLE);
        assert_eq!(os["PRETTY_NAME"], "Ubuntu 24.04.3 LTS");
        let noble = Os {
            id: "ubuntu".into(),
            version_id: "24.04".into(),
        };
        assert!(check_os(&os, &noble).is_ok());
        let jammy = Os {
            id: "ubuntu".into(),
            version_id: "22.04".into(),
        };
        assert!(check_os(&os, &jammy).is_err());
        assert!(check_os(&parse_os_release("ID=debian\nVERSION_ID=\"12\"\n"), &noble).is_err());
    }

    #[test]
    fn a_wrong_missing_or_removed_package_is_reported() {
        let dpkg = "clang\tii \t1:18.0-59~exp2\ncmake\tii \t3.28.3-1build8\nlibgtk-3-dev\trc \t3.24.41-4ubuntu1.3\n";
        assert_eq!(
            mismatches(&pins(), &installed(dpkg)),
            [
                "cmake is 3.28.3-1build8, pinned 3.28.3-1build7",
                "libgtk-3-dev is not installed, pinned 3.24.41-4ubuntu1.3",
            ]
        );
        let exact = "clang\tii \t1:18.0-59~exp2\ncmake\tii \t3.28.3-1build7\nlibgtk-3-dev\tii \t3.24.41-4ubuntu1.3\n";
        assert!(mismatches(&pins(), &installed(exact)).is_empty());
    }

    #[test]
    fn the_whole_installed_set_must_match_its_pin() {
        let config =
            crate::config::Config::load(&Path::new(env!("CARGO_MANIFEST_DIR")).join("repro.toml"))
                .unwrap();
        let pinned = &config.linux.installed_sha256["x86_64"];
        assert!(check_installed_set(pinned, &config.linux, "x86_64").is_ok());
        assert!(check_installed_set(&"0".repeat(64), &config.linux, "x86_64").is_err());
        assert!(check_installed_set(pinned, &config.linux, "riscv64").is_err());
    }
}
