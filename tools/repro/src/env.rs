use anyhow::{Context, Result, bail};
use std::collections::BTreeMap;
use std::ffi::{OsStr, OsString};
use std::path::{Path, PathBuf};
use std::process::Command;

use crate::sandbox::Sandbox;

/// The fixed layout under the config's root. Only `downloads` survives a
/// clean: everything in it is re-verified before use.
pub struct Layout {
    pub root: PathBuf,
}

impl Layout {
    pub fn downloads(&self) -> PathBuf {
        self.root.join("downloads")
    }
    pub fn tool(&self, name: &str) -> PathBuf {
        self.root.join("tools").join(name)
    }
    /// Under `downloads` because its registry cache is a download store too,
    /// and at a fixed path because crate source paths reach the binary.
    pub fn cargo_home(&self) -> PathBuf {
        self.downloads().join("cargo")
    }
    pub fn pub_cache(&self) -> PathBuf {
        self.root.join("pub-cache")
    }
    pub fn home(&self) -> PathBuf {
        self.root.join("home")
    }
    pub fn tmp(&self) -> PathBuf {
        self.root.join("tmp")
    }
    pub fn src(&self) -> PathBuf {
        self.root.join("src")
    }
    /// The Linux build's root filesystem.
    pub fn system(&self) -> PathBuf {
        self.root.join("system")
    }

    /// Deletes everything under the root except the download store.
    pub fn clean(&self) -> Result<()> {
        if !self.root.exists() {
            return Ok(());
        }
        for entry in std::fs::read_dir(&self.root)? {
            let path = entry?.path();
            if path != self.downloads() {
                remove(&path)?;
            }
        }
        Ok(())
    }
}

fn remove(path: &Path) -> Result<()> {
    if std::fs::symlink_metadata(path)?.is_dir() {
        std::fs::remove_dir_all(path)
    } else {
        std::fs::remove_file(path)
    }
    .with_context(|| format!("removing {}", path.display()))
}

/// The only environment a build step sees. Commands start from an empty
/// environment, so nothing from the invoking shell (Homebrew on PATH, SDKROOT,
/// a stray RUSTUP_TOOLCHAIN) can reach the build.
#[derive(Clone)]
pub struct Env {
    vars: BTreeMap<&'static str, OsString>,
    path: Vec<PathBuf>,
    sandbox: Option<Sandbox>,
}

const SYSTEM_PATH: [&str; 4] = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"];

impl Env {
    pub fn new(layout: &Layout) -> Self {
        let user = std::env::var_os("USER").unwrap_or_default();
        let mut env = Env {
            vars: BTreeMap::new(),
            path: Vec::new(),
            sandbox: None,
        };
        env.set("HOME", layout.home())
            .set("TMPDIR", layout.tmp())
            .set("CARGO_HOME", layout.cargo_home())
            .set("PUB_CACHE", layout.pub_cache())
            .set("LANG", "en_US.UTF-8")
            .set("LC_ALL", "en_US.UTF-8")
            .set("TZ", "UTC")
            .set("USER", &user)
            .set("LOGNAME", &user)
            .set("COCOAPODS_DISABLE_STATS", "true")
            .set("FLUTTER_SUPPRESS_ANALYTICS", "true");
        env
    }

    pub fn set(&mut self, key: &'static str, value: impl AsRef<OsStr>) -> &mut Self {
        self.vars.insert(key, value.as_ref().to_owned());
        self
    }

    /// Runs every command from now on inside `sandbox`.
    pub fn sandbox(&mut self, sandbox: Sandbox) -> &mut Self {
        self.sandbox = Some(sandbox);
        self
    }

    /// Puts `dir` ahead of the directories already on PATH.
    pub fn prepend_path(&mut self, dir: PathBuf) -> &mut Self {
        self.path.insert(0, dir);
        self
    }

    pub fn command(&self, program: impl AsRef<OsStr>) -> Command {
        let path = std::env::join_paths(
            self.path
                .iter()
                .map(PathBuf::as_path)
                .chain(SYSTEM_PATH.iter().map(Path::new)),
        )
        .expect("tool paths contain no ':'");
        // The umask decides the modes of every file the build writes, and
        // modes are inside the comparison boundary.
        let mut cmd = match &self.sandbox {
            Some(sandbox) => {
                let mut cmd = match sandbox.userns() {
                    // bubblewrap takes the namespace as an open fd.
                    Some(_) => {
                        let mut cmd = Command::new("/bin/sh");
                        cmd.arg("-c")
                            .arg("exec \"$0\" \"$@\" 3<\"$REPRO_USERNS\"")
                            .arg(sandbox.bwrap());
                        cmd
                    }
                    None => Command::new(sandbox.bwrap()),
                };
                cmd.args(sandbox.args()).arg("/bin/sh");
                cmd
            }
            None => Command::new("/bin/sh"),
        };
        cmd.arg("-c")
            .arg("umask 022 && exec \"$0\" \"$@\"")
            .arg(program);
        cmd.env_clear().envs(&self.vars).env("PATH", path);
        if let Some(ns) = self.sandbox.as_ref().and_then(Sandbox::userns) {
            cmd.env("REPRO_USERNS", ns);
        }
        cmd
    }
}

pub fn run(cmd: &mut Command) -> Result<()> {
    let status = cmd.status().with_context(|| format!("starting {cmd:?}"))?;
    if !status.success() {
        bail!("{cmd:?} failed: {status}");
    }
    Ok(())
}

pub fn output(cmd: &mut Command) -> Result<String> {
    let out = cmd.output().with_context(|| format!("starting {cmd:?}"))?;
    if !out.status.success() {
        bail!(
            "{cmd:?} failed: {}\n{}",
            out.status,
            String::from_utf8_lossy(&out.stderr)
        );
    }
    Ok(String::from_utf8(out.stdout)?.trim().to_owned())
}

pub fn fresh_dir(dir: &Path) -> Result<()> {
    if dir.exists() {
        std::fs::remove_dir_all(dir).with_context(|| format!("removing {}", dir.display()))?;
    }
    std::fs::create_dir_all(dir).with_context(|| format!("creating {}", dir.display()))
}
