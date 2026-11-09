//! A content-addressed download store. A file is only ever handed out after
//! its sha256 has been checked against the pin, including on a cache hit.

use crate::config::Download;
use crate::env::{self, Env};
use crate::manifest;
use anyhow::{Context, Result, bail};
use std::path::{Path, PathBuf};
use std::process::Command;

pub fn fetch(downloads: &Path, d: &Download) -> Result<PathBuf> {
    let dir = downloads.join("sha256");
    std::fs::create_dir_all(&dir)?;
    let path = dir.join(&d.sha256);
    if !path.exists() {
        let partial = path.with_extension("partial");
        eprintln!("fetching {}", d.url);
        env::run(
            Command::new("/usr/bin/curl")
                .args(["--fail", "--silent", "--show-error", "--location"])
                // A long download over a flaky link can lose its connection
                // midway; the hash check below catches anything worse.
                .args(["--retry", "5", "--retry-all-errors", "--output"])
                .arg(&partial)
                .arg(&d.url),
        )?;
        std::fs::rename(&partial, &path)?;
    }
    let got = manifest::sha256_file(&path)?;
    if got != d.sha256 {
        std::fs::remove_file(&path)?;
        bail!("{} has sha256 {got}, pinned {}", d.url, d.sha256);
    }
    Ok(path)
}

/// The file name the URL ends in, for tools that care about extensions.
pub fn file_name(d: &Download) -> Result<&str> {
    d.url
        .rsplit('/')
        .next()
        .filter(|n| !n.is_empty())
        .with_context(|| format!("{} has no file name", d.url))
}

/// Checks the cargo download caches before a build uses them. Cargo only
/// checks a crate's checksum when it downloads it, so every cached registry
/// crate that `lockfile` names is re-hashed against the lockfile, and
/// mismatches are deleted for cargo to download again. Cached git
/// repositories must pass `git fsck`, so the locked commit is the content.
/// Extracted sources and git checkouts are removed, so they are made again
/// from what was just checked.
pub fn verify_cargo_cache(env: &Env, cargo_home: &Path, lockfile: &Path) -> Result<()> {
    let registry = cargo_home.join("registry");
    for derived in [registry.join("src"), cargo_home.join("git/checkouts")] {
        if derived.exists() {
            std::fs::remove_dir_all(&derived)?;
        }
    }
    let git_db = cargo_home.join("git/db");
    if git_db.exists() {
        for repo in std::fs::read_dir(&git_db)? {
            let repo = repo?.path();
            env::run(env.command("git").arg("-C").arg(&repo).args([
                "fsck",
                "--strict",
                "--no-dangling",
                "--no-progress",
            ]))?;
        }
    }
    let cache = registry.join("cache");
    if !cache.exists() {
        return Ok(());
    }
    let lock: toml::Value = toml::from_str(
        &std::fs::read_to_string(lockfile)
            .with_context(|| format!("reading {}", lockfile.display()))?,
    )?;
    let indexes = std::fs::read_dir(&cache)?
        .map(|e| e.map(|e| e.path()))
        .collect::<Result<Vec<_>, _>>()?;
    let mut checked = 0;
    for package in lock
        .get("package")
        .and_then(|p| p.as_array())
        .into_iter()
        .flatten()
    {
        let (Some(name), Some(version), Some(checksum)) = (
            package["name"].as_str(),
            package["version"].as_str(),
            package.get("checksum").and_then(|c| c.as_str()),
        ) else {
            continue;
        };
        for index in &indexes {
            let file = index.join(format!("{name}-{version}.crate"));
            if !file.exists() {
                continue;
            }
            let got = manifest::sha256_file(&file)?;
            if got != checksum {
                eprintln!(
                    "{} has sha256 {got}, Cargo.lock says {checksum}: removing",
                    file.display()
                );
                std::fs::remove_file(&file)?;
            }
            checked += 1;
        }
    }
    eprintln!(
        "checked {checked} cached crates against {}",
        lockfile.display()
    );
    Ok(())
}

#[cfg(test)]
mod test {
    use super::*;
    use crate::env::Layout;
    use std::fs;

    fn scratch(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("repro-test-{}-{name}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn sha256(bytes: &[u8]) -> String {
        use sha2::{Digest, Sha256};
        format!("{:x}", Sha256::digest(bytes))
    }

    #[test]
    fn a_changed_cached_download_is_rejected_and_removed() {
        let downloads = scratch("fetch");
        let pinned = Download {
            url: "https://example.invalid/never-fetched.tar.xz".into(),
            sha256: sha256(b"original"),
        };
        let cached = downloads.join("sha256").join(&pinned.sha256);
        fs::create_dir_all(cached.parent().unwrap()).unwrap();

        fs::write(&cached, b"original").unwrap();
        assert_eq!(fetch(&downloads, &pinned).unwrap(), cached);

        fs::write(&cached, b"tampered").unwrap();
        assert!(fetch(&downloads, &pinned).is_err());
        assert!(!cached.exists());
        fs::remove_dir_all(&downloads).unwrap();
    }

    #[test]
    fn cargo_cache_drops_changed_crates_and_derived_trees() {
        let root = scratch("cargo");
        let cargo_home = root.join("cargo");
        let index = cargo_home.join("registry/cache/index.crates.io-0000000000000000");
        fs::create_dir_all(&index).unwrap();
        fs::create_dir_all(cargo_home.join("registry/src/index/good-1.0.0")).unwrap();
        fs::create_dir_all(cargo_home.join("git/checkouts/dep-0000/abcdef")).unwrap();
        fs::write(index.join("good-1.0.0.crate"), b"good").unwrap();
        fs::write(index.join("bad-1.0.0.crate"), b"tampered").unwrap();
        let lock = root.join("Cargo.lock");
        fs::write(
            &lock,
            format!(
                "[[package]]\nname = \"good\"\nversion = \"1.0.0\"\nchecksum = \"{}\"\n\n[[package]]\nname = \"bad\"\nversion = \"1.0.0\"\nchecksum = \"{}\"\n",
                sha256(b"good"),
                sha256(b"original"),
            ),
        )
        .unwrap();

        verify_cargo_cache(
            &Env::new(&Layout { root: root.clone() }),
            &cargo_home,
            &lock,
        )
        .unwrap();
        assert!(index.join("good-1.0.0.crate").exists());
        assert!(!index.join("bad-1.0.0.crate").exists());
        assert!(!cargo_home.join("registry/src").exists());
        assert!(!cargo_home.join("git/checkouts").exists());
        fs::remove_dir_all(&root).unwrap();
    }
}
