//! The Linux build runs inside an unpacked Ubuntu root under bubblewrap, so
//! the host needs nothing of its own beyond bubblewrap. Paths bound into the
//! sandbox keep their own paths, so what the tool reads and writes on the host
//! is what the build sees inside.

use crate::env;
use anyhow::{Context, Result, bail};
use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::process::{Child, Command};

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum User {
    /// uid 0 in a user namespace, for installing packages into the root.
    Root,
    /// The build user. Ubuntu's base image has `ubuntu` at this uid.
    Builder,
}

#[derive(Clone)]
pub struct Sandbox {
    bwrap: PathBuf,
    root: PathBuf,
    user: User,
    binds: Vec<(PathBuf, bool)>,
    userns: Option<PathBuf>,
}

impl Sandbox {
    pub fn new(bwrap: PathBuf, root: PathBuf, user: User) -> Self {
        Sandbox {
            bwrap,
            root,
            user,
            binds: Vec::new(),
            userns: None,
        }
    }

    /// Runs inside `ns` rather than a namespace of bubblewrap's own, which
    /// maps only one uid.
    pub fn in_namespace(&mut self, ns: &UserNamespace) -> &mut Self {
        self.userns = Some(ns.path());
        self
    }

    /// The user namespace to pass to bubblewrap as fd 3, if any.
    pub fn userns(&self) -> Option<&Path> {
        self.userns.as_deref()
    }

    /// Makes the host's `path` visible at the same path inside.
    pub fn bind(&mut self, path: &Path, writable: bool) -> &mut Self {
        self.binds.push((path.to_owned(), writable));
        self
    }

    pub fn bwrap(&self) -> &Path {
        &self.bwrap
    }

    /// bubblewrap's arguments, up to and excluding the command it runs.
    pub fn args(&self) -> Vec<OsString> {
        let uid = match self.user {
            User::Root => "0",
            User::Builder => "1000",
        };
        let userns: &[&str] = match self.userns {
            Some(_) => &["--userns", "3"],
            None => &["--unshare-user"],
        };
        let mut args: Vec<OsString> = userns
            .iter()
            .chain(&[
                "--unshare-pid",
                "--unshare-ipc",
                "--die-with-parent",
                "--uid",
                uid,
                "--gid",
                uid,
            ])
            .map(OsString::from)
            .collect();
        if self.user == User::Root {
            // bubblewrap drops every capability by default, and dpkg needs
            // CAP_CHOWN and friends. They are the namespace's, not the host's.
            args.push("--cap-add".into());
            args.push("ALL".into());
        }
        args.push("--bind".into());
        args.push(self.root.clone().into());
        args.push("/".into());
        for arg in ["--dev", "/dev", "--proc", "/proc"] {
            args.push(arg.into());
        }
        for (path, writable) in &self.binds {
            args.push(if *writable { "--bind" } else { "--ro-bind" }.into());
            args.push(path.clone().into());
            args.push(path.clone().into());
        }
        args.push("--".into());
        args
    }
}

/// A user namespace in which uid 0 is the invoking user and uids 1 to 65535
/// are its subordinate range from `/etc/subuid`, held open by a sleeping
/// process. dpkg needs it to give files to the system users packages create
/// (messagebus, staff, adm), which a one-uid namespace can't represent.
pub struct UserNamespace {
    holder: Child,
}

const SUBORDINATE_IDS: u32 = 65535;

impl UserNamespace {
    pub fn new() -> Result<Self> {
        let uid = env::output(Command::new("id").arg("-u"))?;
        let gid = env::output(Command::new("id").arg("-g"))?;
        let name = env::output(Command::new("id").arg("-un"))?;
        let subuid = subordinate_range("/etc/subuid", &name, &uid)?;
        let subgid = subordinate_range("/etc/subgid", &name, &uid)?;
        let holder = Command::new("unshare")
            .args(["--user", "--", "sleep", "infinity"])
            .spawn()
            .context("starting unshare")?;
        let ns = UserNamespace { holder };
        ns.wait_for_unshare()?;
        let pid = ns.holder.id().to_string();
        for (program, id, start) in [("newuidmap", &uid, subuid), ("newgidmap", &gid, subgid)] {
            env::run(Command::new(program).args([
                pid.as_str(),
                "0",
                id,
                "1",
                "1",
                &start.to_string(),
                &SUBORDINATE_IDS.to_string(),
            ]))
            .with_context(|| {
                format!("mapping subordinate ids with {program}; install it (Ubuntu: apt install uidmap)")
            })?;
        }
        Ok(ns)
    }

    pub fn path(&self) -> PathBuf {
        PathBuf::from(format!("/proc/{}/ns/user", self.holder.id()))
    }

    fn wait_for_unshare(&self) -> Result<()> {
        let ours = std::fs::read_link("/proc/self/ns/user")?;
        for _ in 0..200 {
            if std::fs::read_link(self.path()).is_ok_and(|ns| ns != ours) {
                return Ok(());
            }
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
        bail!("unshare --user did not start a new user namespace")
    }
}

impl Drop for UserNamespace {
    fn drop(&mut self) {
        let _ = self.holder.kill();
        let _ = self.holder.wait();
    }
}

/// The start of `user`'s range in a subuid or subgid file, which must hold at
/// least [`SUBORDINATE_IDS`] ids.
fn subordinate_range(file: &str, name: &str, uid: &str) -> Result<u32> {
    let text = std::fs::read_to_string(file).with_context(|| {
        format!("reading {file}: installing packages needs a subordinate id range for {name}")
    })?;
    parse_subordinate(&text, name, uid).with_context(|| {
        format!("{file} has no range of at least {SUBORDINATE_IDS} ids for {name}; add one with usermod --add-subuids/--add-subgids")
    })
}

fn parse_subordinate(text: &str, name: &str, uid: &str) -> Option<u32> {
    text.lines().find_map(|line| {
        let mut fields = line.split(':');
        let (owner, start, count) = (fields.next()?, fields.next()?, fields.next()?);
        let count: u32 = count.trim().parse().ok()?;
        ((owner == name || owner == uid) && count >= SUBORDINATE_IDS)
            .then(|| start.trim().parse().ok())
            .flatten()
    })
}

#[cfg(test)]
mod test {
    use super::*;

    #[test]
    fn binds_keep_their_paths_and_the_user_is_mapped() {
        let mut sandbox = Sandbox::new("/usr/bin/bwrap".into(), "/r/system".into(), User::Builder);
        sandbox
            .bind(Path::new("/r"), true)
            .bind(Path::new("/src"), false);
        let args: Vec<String> = sandbox
            .args()
            .into_iter()
            .map(|a| a.into_string().unwrap())
            .collect();
        let joined = args.join(" ");
        assert!(joined.contains("--uid 1000 --gid 1000"));
        assert!(joined.contains("--bind /r/system /"));
        assert!(joined.contains("--bind /r /r"));
        assert!(joined.contains("--ro-bind /src /src"));
        assert_eq!(args.last().unwrap(), "--");
        assert!(joined.starts_with("--unshare-user "));
    }

    #[test]
    fn subordinate_ranges_are_found_by_name_or_uid() {
        let text =
            "other:100000:65536\nllfourn:524288:1073741824\n1001:200000:65536\nsmall:300000:10\n";
        assert_eq!(parse_subordinate(text, "llfourn", "501"), Some(524288));
        assert_eq!(parse_subordinate(text, "runner", "1001"), Some(200000));
        assert_eq!(parse_subordinate(text, "small", "1002"), None);
        assert_eq!(parse_subordinate(text, "nobody", "1003"), None);
    }
}
