//! Linux: the build runs in an Ubuntu root that the tool makes itself, from
//! Ubuntu's base tarball and one snapshot of the archive, under bubblewrap.
//! So the compilers, GTK and libc are the same on any distribution, and the
//! host needs only bubblewrap, curl, tar and git. The whole installed package
//! set is checked against its pin before anything is built.

use crate::app::{self, Build};
use crate::config::{Config, Linux, Os};
use crate::env::{self, Env, Layout};
use crate::sandbox::{Sandbox, User, UserNamespace};
use crate::{store, tools};
use anyhow::{Context, Result, bail};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

const BUNDLE: &str = "frostsnap";

/// The host's CA bundle, which apt trusts until the root has its pinned
/// ca-certificates: the snapshot service is HTTPS-only.
const HOST_CA: &str = "/etc/ssl/certs/ca-certificates.crt";
const ROOT_CA: &str = "etc/ssl/certs/host-ca.crt";

pub struct Target {
    pub arch: &'static str,
    pub triple: &'static str,
    pub flutter: &'static str,
}

/// `arch` as `uname -m` names it.
pub fn target(arch: &str) -> Result<Target> {
    match arch {
        "x86_64" => Ok(Target {
            arch: "x86_64",
            triple: "x86_64-unknown-linux-gnu",
            flutter: "x64",
        }),
        "aarch64" => Ok(Target {
            arch: "aarch64",
            triple: "aarch64-unknown-linux-gnu",
            flutter: "arm64",
        }),
        other => bail!("no Linux build for {other}; use x86_64 or aarch64"),
    }
}

/// Makes the build root afresh, installs every pinned tool into the layout,
/// and returns the environment the build runs in: inside the root, as the
/// build user, with the layout, the repository and `out` bound in.
pub fn prepare(
    config: &Config,
    layout: &Layout,
    t: &Target,
    repo: &Path,
    out: &Path,
) -> Result<Env> {
    let l = config.linux()?;
    let bwrap = find_on_path("bwrap").context(
        "bubblewrap (bwrap) is needed to build the Linux app; install it with your package manager",
    )?;
    remove_root(layout, &bwrap)?;
    layout.clean()?;
    make_root(&l, layout, &bwrap, t)?;

    let mut env = Env::new(layout);
    // The root has no locales; C.UTF-8 is the one glibc always has.
    env.set("LANG", "C.UTF-8").set("LC_ALL", "C.UTF-8");
    let git_dir = PathBuf::from(env::output(
        Command::new("git").arg("-C").arg(repo).args([
            "rev-parse",
            "--path-format=absolute",
            "--git-common-dir",
        ]),
    )?);
    let mut sandbox = Sandbox::new(bwrap, layout.system(), User::Builder);
    sandbox
        .bind(&layout.root, true)
        .bind(repo, false)
        .bind(&git_dir, false)
        .bind(out, true);
    env.sandbox(sandbox);

    check_system(&l, &env, layout, t)?;
    let rust = l
        .rust
        .get(t.triple)
        .with_context(|| format!("no rust pin for {} in linux.toml", t.triple))?;
    env.prepend_path(tools::rust(layout, &env, rust)?);
    app::cargo_tools(config, layout, &mut env)?;
    app::flutter(
        config,
        layout,
        &mut env,
        &format!("linux-{}", t.flutter),
        t.triple,
    )?;
    app::check_versions(config, &env)?;
    Ok(env)
}

pub fn build(
    config: &Config,
    layout: &Layout,
    env: &Env,
    repo: &Path,
    t: &Target,
    b: &Build,
) -> Result<()> {
    let app::Generated {
        app_dir,
        mut env,
        firmware,
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
        .set("BUNDLE_FIRMWARE", "1");
    env::run(
        env.command("flutter")
            .args(["build", "linux", "--release", "--target-platform"])
            .arg(format!("linux-{}", t.flutter))
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
            .arg(app_dir.join(format!("build/linux/{}/release/bundle", t.flutter)))
            .arg(&out),
    )?;
    let os = parse_os_release(&fs::read_to_string(layout.system().join("etc/os-release"))?);
    let kernel = env::output(Command::new("uname").arg("-r"))?;
    let installed_sha256 = installed_set_sha256(&env)?;
    app::write_record(
        b,
        &out,
        &firmware,
        &format!(
            "arch={}\nos={}\nkernel={kernel}\ndpkg_sha256={installed_sha256}\n",
            t.arch,
            os.get("PRETTY_NAME")
                .map(String::as_str)
                .unwrap_or("unknown"),
        ),
    )
}

pub fn bundle(out: &Path) -> PathBuf {
    out.join(BUNDLE)
}

/// Unpacks Ubuntu's base tarball into the layout's system root, points apt
/// at the pinned snapshot, and installs the pinned packages as root inside a
/// user namespace.
fn make_root(l: &Linux, layout: &Layout, bwrap: &Path, t: &Target) -> Result<()> {
    let base = l
        .base
        .get(t.arch)
        .with_context(|| format!("no base pin for {} in linux.toml", t.arch))?;
    let tarball = store::fetch(&layout.downloads(), base)?;
    let root = layout.system();
    env::fresh_dir(&root)?;
    eprintln!("unpacking {}", base.url);
    env::run(
        Command::new("tar")
            .args(["-xzf"])
            .arg(&tarball)
            .arg("-C")
            .arg(&root),
    )?;

    let sources = root.join("etc/apt/sources.list.d");
    let stock = sources.join("ubuntu.sources");
    if stock.exists() {
        fs::remove_file(&stock)?;
    }
    fs::write(
        sources.join("snapshot.list"),
        snapshot_sources(&l.apt_snapshot),
    )?;
    let resolv = root.join("etc/resolv.conf");
    if fs::symlink_metadata(&resolv).is_ok() {
        fs::remove_file(&resolv)?;
    }
    fs::copy("/etc/resolv.conf", &resolv).context("copying the host's /etc/resolv.conf")?;
    let ca = root.join(ROOT_CA);
    fs::create_dir_all(ca.parent().expect("has parent"))?;
    fs::copy(HOST_CA, &ca).with_context(|| format!("copying the host's {HOST_CA}"))?;

    let mut env = Env::new(layout);
    env.set("HOME", "/root")
        .set("TMPDIR", "/tmp")
        .set("LANG", "C.UTF-8")
        .set("LC_ALL", "C.UTF-8")
        .set("DEBIAN_FRONTEND", "noninteractive");
    let ns = UserNamespace::new()?;
    let mut sandbox = Sandbox::new(bwrap.to_owned(), root, User::Root);
    sandbox.in_namespace(&ns);
    env.sandbox(sandbox);
    let apt = |args: &[&str]| {
        let mut cmd = env.command("apt-get");
        cmd.args(["-qq", "-o"])
            .arg(format!("Acquire::https::CAInfo=/{ROOT_CA}"))
            // apt otherwise drops to the _apt user, which the namespace doesn't map.
            .args(["-o", "APT::Sandbox::User=root"])
            .args(args);
        cmd
    };
    env::run(&mut apt(&["update"]))?;
    let packages: Vec<String> = l
        .packages
        .iter()
        .map(|(name, version)| format!("{name}={version}"))
        .collect();
    env::run(apt(&["install", "-y", "--no-install-recommends"]).args(&packages))
}

/// A previous build's root has files dpkg gave to system users, which belong
/// to the invoking user's subordinate uids and so can only be removed from
/// inside a namespace that maps them.
fn remove_root(layout: &Layout, bwrap: &Path) -> Result<()> {
    let root = layout.system();
    if fs::symlink_metadata(&root).is_err() {
        return Ok(());
    }
    let ns = UserNamespace::new()?;
    env::run(
        Command::new("/bin/sh")
            .arg("-c")
            .arg("exec \"$0\" \"$@\" 3<\"$REPRO_USERNS\"")
            .arg(bwrap)
            .args([
                "--userns",
                "3",
                "--cap-add",
                "ALL",
                "--uid",
                "0",
                "--gid",
                "0",
            ])
            .args(["--ro-bind", "/", "/", "--bind"])
            .arg(&layout.root)
            .arg(&layout.root)
            .args(["--", "rm", "-rf"])
            .arg(&root)
            .env("REPRO_USERNS", ns.path()),
    )
    .with_context(|| format!("removing the previous build root {}", root.display()))
}

fn snapshot_sources(snapshot: &str) -> String {
    ["noble", "noble-updates", "noble-security"]
        .iter()
        .map(|suite| format!("deb [signed-by=/usr/share/keyrings/ubuntu-archive-keyring.gpg] https://snapshot.ubuntu.com/ubuntu/{snapshot} {suite} main universe\n"))
        .collect()
}

fn check_system(l: &Linux, env: &Env, layout: &Layout, t: &Target) -> Result<()> {
    let text = fs::read_to_string(layout.system().join("etc/os-release"))
        .context("reading the root's /etc/os-release")?;
    check_os(&parse_os_release(&text), &l.os)?;
    let out = env::output(
        env.command("dpkg-query")
            .args([
                "-W",
                "-f",
                "${Package}\\t${db:Status-Abbrev}\\t${Version}\\n",
            ])
            .args(l.packages.keys()),
    )?;
    let wrong = mismatches(&l.packages, &installed(&out));
    if !wrong.is_empty() {
        bail!(
            "the root's packages differ from the pins:\n  {}",
            wrong.join("\n  ")
        );
    }
    check_installed_set(&installed_set_sha256(env)?, l, t.arch)
}

/// The packages above are the ones the build names, but every installed
/// package (libc, GTK's own dependencies) can shape the app, so the whole set
/// is pinned too.
fn check_installed_set(got: &str, l: &Linux, arch: &str) -> Result<()> {
    let pinned = l.installed_sha256.get(arch).with_context(|| {
        format!("no installed_sha256 pin for {arch} in linux.toml; this root's is {got}")
    })?;
    if got != pinned {
        bail!("the root's installed package set has hash {got}, pinned {pinned} for {arch}");
    }
    Ok(())
}

/// sha256 of `dpkg-query -W`'s full listing, without its final newline: every
/// installed package, with its version and architecture.
fn installed_set_sha256(env: &Env) -> Result<String> {
    let listing = env::output(env.command("dpkg-query").args([
        "-W",
        "-f",
        "${Package} ${Version} ${Architecture}\\n",
    ]))?;
    Ok(format!("{:x}", Sha256::digest(listing.as_bytes())))
}

fn find_on_path(program: &str) -> Result<PathBuf> {
    std::env::split_paths(&std::env::var_os("PATH").unwrap_or_default())
        .map(|dir| dir.join(program))
        .find(|path| path.is_file())
        .with_context(|| format!("{program} is not on PATH"))
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
        let mut linux =
            crate::config::Config::load(&Path::new(env!("CARGO_MANIFEST_DIR")).join("repro.toml"))
                .unwrap()
                .linux()
                .unwrap();
        let pinned = "a".repeat(64);
        linux
            .installed_sha256
            .insert("x86_64".into(), pinned.clone());
        assert!(check_installed_set(&pinned, &linux, "x86_64").is_ok());
        assert!(check_installed_set(&"0".repeat(64), &linux, "x86_64").is_err());
        assert!(check_installed_set(&pinned, &linux, "riscv64").is_err());
    }

    #[test]
    fn snapshot_sources_name_every_suite_at_the_snapshot() {
        let list = snapshot_sources("20261101T000000Z");
        assert_eq!(list.lines().count(), 3);
        for suite in ["noble ", "noble-updates ", "noble-security "] {
            assert!(
                list.contains(&format!(
                    "https://snapshot.ubuntu.com/ubuntu/20261101T000000Z {suite}main universe"
                )),
                "{suite}"
            );
        }
    }

    #[test]
    fn targets_are_known_for_both_arches_only() {
        assert_eq!(target("x86_64").unwrap().flutter, "x64");
        assert_eq!(
            target("aarch64").unwrap().triple,
            "aarch64-unknown-linux-gnu"
        );
        assert!(target("riscv64").is_err());
    }
}
