use anyhow::{Context, Result, bail};
use serde::Deserialize;
use serde::de::DeserializeOwned;
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

/// `repro.toml`: what every platform's build shares. Each platform's own pins
/// are in `<platform>.toml` beside it.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Config {
    /// Every path that can reach a binary lives under here, so it must be the
    /// same on every machine.
    pub root: PathBuf,
    /// The directory holding the config files, which [`LocalFile`] paths are
    /// relative to.
    #[serde(skip)]
    pub dir: PathBuf,
    pub rust: Rust,
    pub flutter: Flutter,
    /// Build-time tools installed with `cargo install`, each from its
    /// published crate and that crate's own `Cargo.lock`.
    pub cargo_tools: Vec<Crate>,
}

#[derive(Deserialize, Clone)]
#[serde(deny_unknown_fields)]
pub struct Download {
    pub url: String,
    pub sha256: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Rust {
    /// Must equal `rust-toolchain.toml` in the source.
    pub version: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Flutter {
    pub version: String,
    pub git: String,
    pub commit: String,
    /// The Dart SDK zip of the commit's engine, keyed by host triple.
    pub dart_sdk: BTreeMap<String, Download>,
    pub tools_lockfile: LocalFile,
    /// Tree hash of the engine artifacts `flutter precache` downloads, keyed
    /// by Flutter target platform. Flutter fetches these itself, so they are
    /// checked after the fact, and before anything in them runs. A platform
    /// with no pin yet stops after the download, reporting the hash.
    pub cache: BTreeMap<String, String>,
}

/// A file kept beside the config, pinned like a download.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct LocalFile {
    pub path: PathBuf,
    pub sha256: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Crate {
    pub name: String,
    pub version: String,
    #[serde(flatten)]
    pub download: Download,
}

/// `macos.toml`.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Macos {
    pub host: String,
    pub archs: Vec<String>,
    pub xcode: Xcode,
    pub ruby: Ruby,
    pub cocoapods: CocoaPods,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Xcode {
    /// Mandated install path: it is embedded in the app's LC_RPATH.
    pub path: PathBuf,
    pub build: String,
    pub tree_sha256: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Ruby {
    pub path: PathBuf,
    pub version: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CocoaPods {
    pub version: String,
    /// The complete gem closure, installed without dependency resolution.
    pub gems: Vec<Download>,
}

/// `linux.toml`. Keys named `<arch>` are as `uname -m` names the target:
/// `x86_64` or `aarch64`.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Linux {
    /// Ubuntu's base root filesystem tarball, per arch. The build root is made
    /// from it afresh each time.
    pub base: BTreeMap<String, Download>,
    pub os: Os,
    /// A snapshot.ubuntu.com timestamp. apt resolves every package, and every
    /// dependency, from the archive as it was at that moment.
    pub apt_snapshot: String,
    /// Exact versions of the packages the build needs.
    pub packages: BTreeMap<String, String>,
    /// sha256 of the whole installed package set, per arch, as
    /// `dpkg-query -W -f '${Package} ${Version} ${Architecture}\n'` lists it
    /// without its final newline.
    pub installed_sha256: BTreeMap<String, String>,
    /// Rust's component tarballs for the build root, keyed by host triple.
    pub rust: BTreeMap<String, Vec<Download>>,
}

/// `ID` and `VERSION_ID` from `/etc/os-release`.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Os {
    pub id: String,
    pub version_id: String,
}

impl Config {
    pub fn load(path: &Path) -> Result<Self> {
        let mut config: Config = read_toml(path)?;
        config.dir = std::path::absolute(path)?
            .parent()
            .expect("a file has a parent")
            .to_owned();
        Ok(config)
    }

    pub fn macos(&self) -> Result<Macos> {
        read_toml(&self.dir.join("macos.toml"))
    }

    pub fn linux(&self) -> Result<Linux> {
        let linux: Linux = read_toml(&self.dir.join("linux.toml"))?;
        linux.validate()?;
        Ok(linux)
    }

    /// Reads a [`LocalFile`], refusing it unless it matches its pin.
    pub fn read_local(&self, file: &LocalFile) -> Result<Vec<u8>> {
        let path = self.dir.join(&file.path);
        let bytes = std::fs::read(&path).with_context(|| format!("reading {}", path.display()))?;
        let got = format!("{:x}", <sha2::Sha256 as sha2::Digest>::digest(&bytes));
        if got != file.sha256 {
            bail!(
                "{} has sha256 {got}, pinned {}",
                path.display(),
                file.sha256
            );
        }
        Ok(bytes)
    }
}

impl Linux {
    /// Rejects an apt snapshot that isn't a timestamp, which would not name
    /// one state of the archive.
    fn validate(&self) -> Result<()> {
        let s = self.apt_snapshot.as_bytes();
        let is_timestamp = s.len() == 16
            && s[8] == b'T'
            && s[15] == b'Z'
            && s[..8].iter().chain(&s[9..15]).all(u8::is_ascii_digit);
        if !is_timestamp {
            bail!(
                "apt_snapshot {:?} must look like 20261101T000000Z",
                self.apt_snapshot
            );
        }
        if let Some((name, _)) = self.packages.iter().find(|(_, v)| v.is_empty()) {
            bail!("packages.{name} has no version");
        }
        Ok(())
    }
}

fn read_toml<T: DeserializeOwned>(path: &Path) -> Result<T> {
    let text =
        std::fs::read_to_string(path).with_context(|| format!("reading {}", path.display()))?;
    toml::from_str(&text).with_context(|| format!("parsing {}", path.display()))
}

#[cfg(test)]
mod test {
    use super::*;

    fn shipped() -> Config {
        Config::load(&Path::new(env!("CARGO_MANIFEST_DIR")).join("repro.toml")).unwrap()
    }

    #[test]
    fn a_changed_local_file_is_refused() {
        let dir = std::env::temp_dir().join(format!("repro-test-{}-local", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("pubspec.lock"), "original").unwrap();
        let config = Config {
            dir: dir.clone(),
            ..shipped()
        };
        let file = LocalFile {
            path: "pubspec.lock".into(),
            sha256: format!("{:x}", <sha2::Sha256 as sha2::Digest>::digest(b"original")),
        };
        assert_eq!(config.read_local(&file).unwrap(), b"original");
        std::fs::write(dir.join("pubspec.lock"), "tampered").unwrap();
        assert!(config.read_local(&file).is_err());
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn every_platform_file_parses_and_pins_both_linux_arches() {
        let config = shipped();
        let macos = config.macos().unwrap();
        assert!(config.flutter.dart_sdk.contains_key(&macos.host));
        let linux = config.linux().unwrap();
        for (arch, triple) in [
            ("x86_64", "x86_64-unknown-linux-gnu"),
            ("aarch64", "aarch64-unknown-linux-gnu"),
        ] {
            assert!(linux.base.contains_key(arch), "{arch}");
            assert!(linux.rust.contains_key(triple), "{triple}");
            assert!(config.flutter.dart_sdk.contains_key(triple), "{triple}");
        }
    }

    #[test]
    fn a_bad_snapshot_is_rejected() {
        let mut linux = shipped().linux().unwrap();
        assert!(linux.validate().is_ok());
        linux.apt_snapshot = "2026-11-01".into();
        assert!(linux.validate().is_err());
    }
}
