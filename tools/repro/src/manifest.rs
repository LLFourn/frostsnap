//! The comparison boundary: one line per entry, sorted by path,
//! giving the type, then a regular file's permission bits and sha256 or a
//! symlink's literal target. Directories carry no metadata, and timestamps,
//! owners and extended attributes are deliberately outside it.

use anyhow::{Context, Result};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::fs;
use std::io::Read;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

pub fn of_tree(root: &Path) -> Result<String> {
    of_tree_with(root, &[], 0o7777)
}

/// Like [`of_tree`], leaving out any entry whose relative path equals or lies
/// under one of `skip`.
pub fn of_tree_skipping(root: &Path, skip: &[&str]) -> Result<String> {
    of_tree_with(root, skip, 0o7777)
}

/// Like [`of_tree_skipping`], recording only the file mode bits in `mode_mask`.
pub fn of_tree_with(root: &Path, skip: &[&str], mode_mask: u32) -> Result<String> {
    let mut paths = Vec::new();
    walk(root, Path::new(""), skip, &mut paths)?;
    paths.sort_by(|a, b| a.as_os_str().as_bytes().cmp(b.as_os_str().as_bytes()));
    let mut out = String::new();
    for rel in paths {
        out.push_str(&format!(
            "{rel:?} {}\n",
            describe(&root.join(&rel), mode_mask)?
        ));
    }
    Ok(out)
}

pub fn hash(manifest: &str) -> String {
    format!("{:x}", Sha256::digest(manifest.as_bytes()))
}

pub fn sha256_file(path: &Path) -> Result<String> {
    let mut file = fs::File::open(path).with_context(|| format!("opening {}", path.display()))?;
    let mut hasher = Sha256::new();
    let mut buf = vec![0; 1 << 20];
    loop {
        let n = file.read(&mut buf)?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
    }
    Ok(format!("{:x}", hasher.finalize()))
}

/// Entries that are missing, extra or different between two manifests, in
/// path order.
pub fn diff(a: &str, b: &str) -> Vec<String> {
    let (a, b) = (entries(a), entries(b));
    let mut paths: Vec<&str> = a.keys().chain(b.keys()).copied().collect();
    paths.sort();
    paths.dedup();
    paths
        .into_iter()
        .filter_map(|path| match (a.get(path), b.get(path)) {
            (Some(x), Some(y)) if x == y => None,
            (Some(x), Some(y)) => Some(format!("{path} differs: {x} vs {y}")),
            (Some(_), None) => Some(format!("{path} only in the first")),
            (None, _) => Some(format!("{path} only in the second")),
        })
        .collect()
}

fn entries(manifest: &str) -> BTreeMap<&str, &str> {
    manifest
        .lines()
        .map(|line| {
            let end = path_end(line);
            (&line[..end], line[end..].trim_start())
        })
        .collect()
}

fn path_end(line: &str) -> usize {
    let mut escaped = false;
    for (i, c) in line.char_indices().skip(1) {
        match c {
            _ if escaped => escaped = false,
            '\\' => escaped = true,
            '"' => return i + 1,
            _ => {}
        }
    }
    line.len()
}

fn walk(root: &Path, rel: &Path, skip: &[&str], out: &mut Vec<PathBuf>) -> Result<()> {
    let dir = root.join(rel);
    for entry in fs::read_dir(&dir).with_context(|| format!("reading {}", dir.display()))? {
        let entry = entry?;
        let rel = rel.join(entry.file_name());
        if skip.iter().any(|s| rel.starts_with(s)) {
            continue;
        }
        let is_dir = entry.file_type()?.is_dir();
        out.push(rel.clone());
        if is_dir {
            walk(root, &rel, skip, out)?;
        }
    }
    Ok(())
}

fn describe(path: &Path, mode_mask: u32) -> Result<String> {
    let meta = fs::symlink_metadata(path)?;
    let kind = meta.file_type();
    Ok(if kind.is_symlink() {
        format!("link {:?}", fs::read_link(path)?)
    } else if kind.is_dir() {
        "dir".into()
    } else if kind.is_file() {
        format!(
            "file {:04o} {}",
            meta.permissions().mode() & mode_mask,
            sha256_file(path)?
        )
    } else {
        format!("other {:o}", meta.permissions().mode() & 0o170000)
    })
}

#[cfg(test)]
mod test {
    use super::*;

    #[test]
    fn diff_reports_changed_missing_and_extra() {
        let a = "\"a\" dir\n\"a/b\" file 0644 aa\n\"c d\" file 0644 cc\n";
        let b = "\"a\" dir\n\"a/b\" file 0755 aa\n\"e\" link \"a\"\n";
        assert_eq!(
            diff(a, b),
            [
                "\"a/b\" differs: file 0644 aa vs file 0755 aa",
                "\"c d\" only in the first",
                "\"e\" only in the second",
            ]
        );
        assert!(diff(a, a).is_empty());
    }

    #[test]
    fn quoted_path_with_escaped_quote() {
        let m = "\"x\\\" y\" file 0644 aa\n";
        assert_eq!(entries(m).get("\"x\\\" y\""), Some(&"file 0644 aa"));
    }
}
