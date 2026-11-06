use anyhow::{Context, Result};
use serde::Deserialize;
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Config {
    /// Every path that can reach a binary lives under here, so it must be the
    /// same on every machine.
    pub root: PathBuf,
    /// The directory holding the config, which [`LocalFile`] paths are
    /// relative to.
    #[serde(skip)]
    pub dir: PathBuf,
    pub rust: Rust,
    pub flutter: Flutter,
    /// Build-time tools installed with `cargo install`, each from its
    /// published crate and that crate's own `Cargo.lock`.
    pub cargo_tools: Vec<Crate>,
    pub macos: Macos,
    pub linux: Linux,
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
    pub version: String,
    /// Toolchain component tarballs, keyed by host triple.
    pub host: BTreeMap<String, Vec<Download>>,
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
    /// by platform. Flutter fetches these itself, so they are checked after
    /// the fact rather than per file, and before anything in them runs. A
    /// platform with no pin yet stops after the download, reporting the hash.
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

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Linux {
    /// The container image the build runs in, by digest. The tool can't see
    /// it from inside, so it checks `os` and `packages` instead; CI starts
    /// the container from this value.
    pub image: String,
    pub os: Os,
    /// A snapshot.ubuntu.com timestamp. apt resolves every package, and every
    /// dependency, from the archive as it was at that moment.
    pub apt_snapshot: String,
    /// Exact versions of the packages the build needs, checked before it
    /// starts.
    pub packages: BTreeMap<String, String>,
    /// sha256 of the whole installed package set (`dpkg-query -W`), keyed by
    /// architecture as `uname -m` names it.
    pub installed_sha256: BTreeMap<String, String>,
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
        let text =
            std::fs::read_to_string(path).with_context(|| format!("reading {}", path.display()))?;
        let mut config: Config =
            toml::from_str(&text).with_context(|| format!("parsing {}", path.display()))?;
        config.dir = std::path::absolute(path)?
            .parent()
            .expect("a file has a parent")
            .to_owned();
        config.validate()?;
        Ok(config)
    }

    /// Rejects pins that can't mean one thing: a container image named by
    /// tag rather than digest, or an apt snapshot that isn't a timestamp.
    fn validate(&self) -> Result<()> {
        let l = &self.linux;
        let digest = l.image.rsplit_once("@sha256:").map(|(_, d)| d);
        if !digest.is_some_and(|d| d.len() == 64 && d.bytes().all(|b| b.is_ascii_hexdigit())) {
            anyhow::bail!(
                "linux.image {:?} must be pinned by @sha256: digest",
                l.image
            );
        }
        let s = l.apt_snapshot.as_bytes();
        let is_timestamp = s.len() == 16
            && s[8] == b'T'
            && s[15] == b'Z'
            && s[..8].iter().chain(&s[9..15]).all(u8::is_ascii_digit);
        if !is_timestamp {
            anyhow::bail!(
                "linux.apt_snapshot {:?} must look like 20261101T000000Z",
                l.apt_snapshot
            );
        }
        if let Some((name, _)) = l.packages.iter().find(|(_, v)| v.is_empty()) {
            anyhow::bail!("linux.packages.{name} has no version");
        }
        Ok(())
    }

    /// Reads a [`LocalFile`], refusing it unless it matches its pin.
    pub fn read_local(&self, file: &LocalFile) -> Result<Vec<u8>> {
        let path = self.dir.join(&file.path);
        let bytes = std::fs::read(&path).with_context(|| format!("reading {}", path.display()))?;
        let got = format!("{:x}", <sha2::Sha256 as sha2::Digest>::digest(&bytes));
        if got != file.sha256 {
            anyhow::bail!(
                "{} has sha256 {got}, pinned {}",
                path.display(),
                file.sha256
            );
        }
        Ok(bytes)
    }
}

#[cfg(test)]
mod test {
    use super::*;

    #[test]
    fn a_changed_local_file_is_refused() {
        let dir = std::env::temp_dir().join(format!("repro-test-{}-local", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("pubspec.lock"), "original").unwrap();
        let config = Config {
            dir: dir.clone(),
            ..Config::load(&Path::new(env!("CARGO_MANIFEST_DIR")).join("repro.toml")).unwrap()
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
    fn the_shipped_config_is_valid_and_pins_linux_by_digest() {
        let config =
            Config::load(&Path::new(env!("CARGO_MANIFEST_DIR")).join("repro.toml")).unwrap();
        assert!(config.linux.image.contains("@sha256:"));
        for host in [
            config.macos.host.as_str(),
            "x86_64-unknown-linux-gnu",
            "aarch64-unknown-linux-gnu",
        ] {
            assert!(config.rust.host.contains_key(host), "{host}");
            assert!(config.flutter.dart_sdk.contains_key(host), "{host}");
        }
        for arch in ["x86_64", "aarch64"] {
            assert!(config.linux.installed_sha256.contains_key(arch), "{arch}");
        }
    }

    #[test]
    fn a_tag_pinned_image_or_a_bad_snapshot_is_rejected() {
        let mut config =
            Config::load(&Path::new(env!("CARGO_MANIFEST_DIR")).join("repro.toml")).unwrap();
        config.linux.image = "ubuntu:24.04".into();
        assert!(config.validate().is_err());
        config.linux.image = format!("ubuntu:24.04@sha256:{}", "a".repeat(64));
        assert!(config.validate().is_ok());
        config.linux.apt_snapshot = "2026-11-01".into();
        assert!(config.validate().is_err());
    }
}
