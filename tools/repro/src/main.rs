mod app;
mod config;
mod env;
mod linux;
mod macos;
mod manifest;
mod store;
mod tools;

use anyhow::{Context, Result, bail};
use clap::{Args, Parser, Subcommand, ValueEnum};
use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode};

/// Reproducible builds of the Frostsnap app. See tools/repro/README.md.
#[derive(Parser)]
struct Cli {
    /// Defaults to tools/repro/repro.toml in the repository.
    #[arg(long, global = true)]
    config: Option<PathBuf>,
    #[command(subcommand)]
    command: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    /// Download, verify and install every pinned input a platform needs.
    Fetch { platform: Platform },
    /// Build the app from a commit at the fixed root.
    Build {
        platform: Platform,
        #[command(flatten)]
        build: BuildArgs,
    },
    /// Build, then compare the result with an existing unsigned build.
    Verify {
        platform: Platform,
        #[command(flatten)]
        build: BuildArgs,
        /// The bundle (or its manifest) to compare against.
        #[arg(long)]
        against: PathBuf,
    },
    /// Delete everything under the root except the download store.
    Clean {
        /// Delete the download store too.
        #[arg(long)]
        downloads: bool,
    },
    /// Print the comparison manifest of a tree.
    Manifest {
        tree: PathBuf,
        /// Print only the manifest's sha256.
        #[arg(long)]
        hash: bool,
    },
    /// Print an Xcode's tree hash, as `macos.xcode.tree_sha256` pins it.
    XcodeHash { xcode: PathBuf },
    /// Compare trees or manifest files; exits non-zero on any difference.
    Compare {
        #[arg(required = true, num_args = 2..)]
        paths: Vec<PathBuf>,
    },
}

#[derive(Args)]
struct BuildArgs {
    #[arg(long, default_value = "HEAD")]
    commit: String,
    /// The firmware image to bundle. It must be signed by `--env`'s
    /// secure-boot key, unless `--unsigned-firmware` is given.
    #[arg(long)]
    firmware: PathBuf,
    /// Skip the firmware's secure-boot signature check, for placeholder
    /// firmware. Only allowed with `--env dev`, and recorded in build.env.
    #[arg(long)]
    unsigned_firmware: bool,
    #[arg(long, default_value = "prod")]
    env: String,
    /// Where the bundle, its manifest and build.env are written.
    #[arg(long)]
    out: PathBuf,
}

#[derive(Clone, Copy, ValueEnum)]
enum Platform {
    Macos,
    Linux,
}

impl Platform {
    fn bundle(self, out: &Path) -> PathBuf {
        match self {
            Platform::Macos => macos::bundle(out),
            Platform::Linux => linux::bundle(out),
        }
    }
}

const SHOWN_DIFFERENCES: usize = 20;

fn main() -> ExitCode {
    match run(Cli::parse()) {
        Ok(true) => ExitCode::SUCCESS,
        Ok(false) => ExitCode::FAILURE,
        Err(e) => {
            eprintln!("error: {e:#}");
            ExitCode::FAILURE
        }
    }
}

fn run(cli: Cli) -> Result<bool> {
    match cli.command {
        Cmd::Manifest { tree, hash } => {
            let m = manifest::of_tree(&tree)?;
            if hash {
                println!("{}", manifest::hash(&m));
            } else {
                print!("{m}");
            }
            Ok(true)
        }
        Cmd::XcodeHash { xcode } => {
            println!("{}", macos::xcode_hash(&xcode)?);
            Ok(true)
        }
        Cmd::Compare { paths } => {
            let first = load_manifest(&paths[0])?;
            let mut same = true;
            for other in &paths[1..] {
                same &= report(&paths[0], &first, other, &load_manifest(other)?);
            }
            Ok(same)
        }
        Cmd::Clean { downloads } => {
            let (config, _) = load_config(cli.config)?;
            let layout = env::Layout {
                root: config.root.clone(),
            };
            if downloads && layout.root.exists() {
                std::fs::remove_dir_all(&layout.root)?;
            } else {
                layout.clean()?;
            }
            Ok(true)
        }
        Cmd::Fetch { platform } => {
            let (config, _) = load_config(cli.config)?;
            let layout = env::Layout {
                root: config.root.clone(),
            };
            match platform {
                Platform::Macos => macos::prepare(&config, &layout)?,
                Platform::Linux => linux::prepare(&config, &layout)?,
            };
            Ok(true)
        }
        Cmd::Build { platform, build } => {
            build_app(cli.config, platform, &build)?;
            Ok(true)
        }
        Cmd::Verify {
            platform,
            build,
            against,
        } => {
            check_reference_outside(&against, &build.out)?;
            let reference = load_manifest(&against)?;
            let out = build_app(cli.config, platform, &build)?;
            let ours = platform.bundle(&out);
            Ok(report(
                &ours,
                &manifest::of_tree(&ours)?,
                &against,
                &reference,
            ))
        }
    }
}

fn build_app(config: Option<PathBuf>, platform: Platform, args: &BuildArgs) -> Result<PathBuf> {
    let (config, repo) = load_config(config)?;
    let layout = env::Layout {
        root: config.root.clone(),
    };
    let commit = git(
        &repo,
        &[
            "rev-parse",
            "--verify",
            &format!("{}^{{commit}}", args.commit),
        ],
    )?;
    // A fixed abbreviation: git otherwise sizes it by the repository's object
    // count, so a fork or shallow clone describes the same commit differently.
    let version = git(
        &repo,
        &["describe", "--tags", "--always", "--abbrev=12", &commit],
    )?;
    if args.unsigned_firmware && args.env != "dev" {
        bail!("--unsigned-firmware is only allowed with --env dev");
    }
    let firmware = std::path::absolute(&args.firmware)?;
    std::fs::create_dir_all(&args.out)?;
    let out = std::path::absolute(&args.out)?;
    if out.starts_with(&layout.root) {
        bail!(
            "--out must be outside {}, which every build clears",
            layout.root.display()
        );
    }
    let build = app::Build {
        commit: &commit,
        version: &version,
        env: &args.env,
        firmware: &firmware,
        unsigned_firmware: args.unsigned_firmware,
        out: &out,
    };
    match platform {
        Platform::Macos => {
            let env = macos::prepare(&config, &layout)?;
            macos::build(&config, &layout, &env, &repo, &build)?;
        }
        Platform::Linux => {
            let env = linux::prepare(&config, &layout)?;
            linux::build(&config, &layout, &env, &repo, &build)?;
        }
    }
    Ok(out)
}

/// A build replaces everything it writes under `out`, so a reference there
/// would be compared with the new build instead of with itself.
fn check_reference_outside(reference: &Path, out: &Path) -> Result<()> {
    let reference = reference
        .canonicalize()
        .with_context(|| format!("reading {}", reference.display()))?;
    if let Ok(out) = out.canonicalize()
        && reference.starts_with(&out)
    {
        bail!(
            "--against {} is inside --out {}, which the build overwrites",
            reference.display(),
            out.display()
        );
    }
    Ok(())
}

fn load_config(path: Option<PathBuf>) -> Result<(config::Config, PathBuf)> {
    let repo = PathBuf::from(git(Path::new("."), &["rev-parse", "--show-toplevel"])?);
    let path = path.unwrap_or_else(|| repo.join("tools/repro/repro.toml"));
    Ok((config::Config::load(&path)?, repo))
}

fn load_manifest(path: &Path) -> Result<String> {
    if path.is_dir() {
        manifest::of_tree(path)
    } else {
        std::fs::read_to_string(path).with_context(|| format!("reading {}", path.display()))
    }
}

fn report(a_name: &Path, a: &str, b_name: &Path, b: &str) -> bool {
    let differences = manifest::diff(a, b);
    if differences.is_empty() {
        println!(
            "{} and {} match ({})",
            a_name.display(),
            b_name.display(),
            manifest::hash(a)
        );
        return true;
    }
    println!(
        "{} and {} differ in {} entries:",
        a_name.display(),
        b_name.display(),
        differences.len()
    );
    for d in differences.iter().take(SHOWN_DIFFERENCES) {
        println!("  {d}");
    }
    if differences.len() > SHOWN_DIFFERENCES {
        println!("  ...");
    }
    false
}

fn git(repo: &Path, args: &[&str]) -> Result<String> {
    env::output(Command::new("git").arg("-C").arg(repo).args(args))
}

#[cfg(test)]
mod test {
    use super::*;

    #[test]
    fn reference_inside_out_is_refused_even_through_a_symlink() {
        let dir = std::env::temp_dir().join(format!("repro-test-{}-reference", std::process::id()));
        let out = dir.join("out");
        std::fs::create_dir_all(out.join("Frostsnap.app")).unwrap();
        std::fs::write(out.join("manifest"), "").unwrap();
        std::os::unix::fs::symlink(&out, dir.join("alias")).unwrap();

        assert!(check_reference_outside(&out.join("manifest"), &out).is_err());
        assert!(check_reference_outside(&dir.join("alias/Frostsnap.app"), &out).is_err());
        assert!(check_reference_outside(&out, &dir.join("alias")).is_err());
        std::fs::write(dir.join("elsewhere"), "").unwrap();
        assert!(check_reference_outside(&dir.join("elsewhere"), &out).is_ok());
        assert!(check_reference_outside(&dir.join("elsewhere"), &dir.join("not-yet")).is_ok());
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
