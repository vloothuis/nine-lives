//! nl-engine: Nine Lives' backup engine, built on rustic_core. It writes plain restic repositories.
//!
//! - `backup` walks the sources completely (a full sweep).
//! - `splice` reads only changed folders and keeps the rest from the parent snapshot.
//!
//! See docs/design/backup-engine.md for the design, the protocol and the threat model.

mod filter;
mod gitignored;
mod lock;
mod output;
mod retry;
mod sample;
mod sftp;
mod splice;
mod store;
mod sweep;
mod walk;

use std::{
    path::{Component, Path, PathBuf},
    process::ExitCode,
    sync::{Arc, Mutex, atomic::{AtomicBool, Ordering}},
};

use anyhow::{Context, Result, anyhow, bail};
use rustic_backend::BackendOptions;
use rustic_core::{
    Credentials, IndexedIdsStatus, Repository, RepositoryBackends, RepositoryOptions,
    repofile::SnapshotFile,
};
use serde_json::json;

use crate::{
    filter::{CACHEDIR_TAG, Marker, PatternList},
    gitignored::GitIgnored,
    lock::{Codec, Lock, Locked, State},
    output::{Bars, Out},
    store::{Guarded, LocalStore, Store},
    walk::{Filter, Walker},
};

pub type Repo = Repository<IndexedIdsStatus>;

/// An absolute path has no `.` or `..` components.
pub fn is_clean(p: &Path) -> bool {
    !p.components().any(|c| matches!(c, Component::ParentDir | Component::CurDir))
        && !p.to_string_lossy().contains("//")
}

#[derive(Default, Debug)]
struct Args {
    command: String,
    repo: Option<String>,
    ssh: Option<Vec<String>>,
    cache_dir: Option<PathBuf>,
    host: Option<String>,
    tags: Vec<String>,
    parent: Option<String>,
    force: bool,
    changed: Option<PathBuf>,
    excludes: Vec<String>,
    markers: Vec<String>,
    gitignored: Vec<String>,
    one_file_system: bool,
    sources: Vec<PathBuf>,
}

fn parse_args(raw: Vec<String>) -> Result<Args> {
    let mut it = raw.into_iter();
    let mut a = Args { command: it.next().context("usage: nl-engine backup|splice ...")?, ..Args::default() };
    if a.command != "backup" && a.command != "splice" {
        bail!("unknown command {}", a.command);
    }
    while let Some(arg) = it.next() {
        let mut val = || it.next().ok_or_else(|| anyhow!("{arg} needs a value"));
        match arg.as_str() {
            "--repo" => a.repo = Some(val()?),
            "--ssh-json" => a.ssh = Some(serde_json::from_str(&val()?).context("--ssh-json must be a JSON array of strings")?),
            "--cache-dir" => a.cache_dir = Some(PathBuf::from(val()?)),
            "--host" => a.host = Some(val()?),
            "--tag" => a.tags.push(val()?),
            "--parent" => a.parent = Some(val()?),
            "--force" => a.force = true,
            "--changed" => a.changed = Some(PathBuf::from(val()?)),
            "--exclude" => a.excludes.push(val()?),
            "--exclude-if-present" => a.markers.push(val()?),
            "--exclude-gitignored" => a.gitignored.push(val()?),
            "--exclude-caches" => a.markers.push(CACHEDIR_TAG.into()),
            "--one-file-system" => a.one_file_system = true,
            "--" => a.sources.extend(it.by_ref().map(PathBuf::from)),
            s if s.starts_with("--") => bail!("unknown argument {s}"),
            s => a.sources.push(PathBuf::from(s)),
        }
    }
    if a.command == "splice" && (a.parent.is_none() || a.changed.is_none()) {
        bail!("splice needs --parent and --changed");
    }
    if a.command == "splice" && a.force {
        bail!("--force is only for backup");
    }
    Ok(a)
}

struct RepoCodec(Arc<Repo>);

impl Codec for RepoCodec {
    fn encode(&self, data: &[u8]) -> Result<Vec<u8>> {
        self.0.encode_unpacked(data).map_err(|e| anyhow!("{}", e.display_log()))
    }
    fn decode(&self, data: &[u8]) -> Result<Vec<u8>> {
        self.0.decode_unpacked(data).map_err(|e| anyhow!("{}", e.display_log()))
    }
}

/// The lock to remove when a signal arrives.
static LOCK: Mutex<Option<Arc<Lock>>> = Mutex::new(None);
/// Set while the lock is acquired, so a signal must wait until the lock is in `LOCK`.
static ACQUIRING: AtomicBool = AtomicBool::new(false);
/// Set when a signal arrived while the lock was acquired.
static SIGNALED: AtomicBool = AtomicBool::new(false);

/// Removes the lock and exits with 130. Nothing refers to packs written so far, and no snapshot
/// was saved.
fn release_and_exit(l: &Lock) -> ! {
    l.release();
    std::process::exit(130);
}

fn install_signal_handler() -> Result<()> {
    use signal_hook::consts::{SIGINT, SIGTERM};
    let mut signals = signal_hook::iterator::Signals::new([SIGINT, SIGTERM])?;
    _ = std::thread::spawn(move || {
        if signals.forever().next().is_some() {
            let mut slot = LOCK.lock().unwrap();
            match slot.take() {
                Some(l) => release_and_exit(&l),
                None if !ACQUIRING.load(Ordering::SeqCst) => std::process::exit(130),
                // A lock file may exist already; main releases it once acquire returns.
                None => SIGNALED.store(true, Ordering::SeqCst),
            }
        }
    });
    Ok(())
}

fn open(args: &Args, out: &Arc<Out>, state: &Arc<State>) -> Result<(Arc<Repo>, Arc<dyn Store>)> {
    let repo = args.repo.clone().context("--repo is required")?;
    let password = std::env::var("NL_ENGINE_PASSWORD").context("NL_ENGINE_PASSWORD is not set")?;
    let (be, store): (Arc<dyn rustic_core::WriteBackend>, Arc<dyn Store>) = match &args.ssh {
        Some(ssh) => sftp::connect(ssh, &repo)?,
        None => {
            if !Path::new(&repo).is_absolute() {
                bail!("--repo must be an absolute path");
            }
            let be = BackendOptions::default().repository(repo.clone()).to_backends()?.repository();
            (be, Arc::new(LocalStore(PathBuf::from(&repo))))
        }
    };
    if be.list(rustic_core::FileType::Config)?.is_empty() {
        return Err(RepoMissing(repo).into());
    }
    let guarded = Arc::new(Guarded { inner: be, state: state.clone() });
    let backends = RepositoryBackends::new(guarded, None);
    let mut opts = RepositoryOptions::default();
    match &args.cache_dir {
        Some(d) => opts.cache_dir = Some(d.clone()),
        None => opts.no_cache = true,
    }
    let r = Repository::new_with_progress(&opts, &backends, Bars(out.clone()))?
        .open(&Credentials::password(password))?
        .to_indexed_ids()?;
    Ok((Arc::new(r), store))
}

fn build_filter(args: &Args) -> Result<Filter> {
    PatternList::validate(&args.excludes).map_err(|e| anyhow!(e))?;
    let markers = args.markers.iter().map(|m| Marker::parse(m)).collect::<Result<Vec<_>, _>>().map_err(|e| anyhow!(e))?;
    let gitignored = Arc::new(GitIgnored::new(args.gitignored.clone()).map_err(|e| anyhow!(e))?);
    Ok(Filter { patterns: PatternList::new(&args.excludes), markers, gitignored, one_file_system: args.one_file_system })
}

fn summary(out: &Out, repo: &Repo, kind: &str, snap: &SnapshotFile, hard_links_changed: bool) -> Result<()> {
    let s = snap.summary.clone().unwrap_or_default();
    let sample = sample::sample(repo, snap.tree)?;
    out.emit(&json!({
        "type": "summary",
        "snapshot_id": snap.id.to_hex().to_string(),
        "parent": snap.parent.map(|p| p.to_hex().to_string()),
        "tree": snap.tree.to_hex().to_string(),
        "kind": if kind == "backup" { "backup" } else { "splice" },
        "files": s.total_files_processed,
        "bytes": s.total_bytes_processed,
        "files_new": s.files_new,
        "files_changed": s.files_changed,
        "data_added": s.data_added,
        "data_added_packed": s.data_added_packed,
        "duration": s.backup_duration,
        "hard_links_changed": hard_links_changed,
        "sample": sample,
    }));
    Ok(())
}

fn run(args: Args) -> Result<()> {
    install_signal_handler()?;
    retry::raise_open_file_limit();
    let out = Out::new(args.command == "backup");
    let filter = Arc::new(build_filter(&args)?);
    let sources = walk::normalize_sources(&args.sources)?;
    let walker = Walker::new(filter, out.clone(), &sources)?;
    let state = Arc::new(State::default());
    let (repo, store) = open(&args, &out, &state)?;

    ACQUIRING.store(true, Ordering::SeqCst);
    let lock = Arc::new(Lock::acquire(store, Arc::new(RepoCodec(repo.clone())), state)?);
    {
        let mut slot = LOCK.lock().unwrap();
        if SIGNALED.load(Ordering::SeqCst) {
            release_and_exit(&lock);
        }
        *slot = Some(lock.clone());
    }
    let result = (|| -> Result<(SnapshotFile, bool)> {
        if args.command == "backup" {
            let host = args.host.as_deref().context("--host is required")?;
            let done = sweep::run(&repo, walker, &sources, host, &args.tags, args.parent.as_deref(), args.force)?;
            Ok((done.snap, false))
        } else {
            let parent = args.parent.as_deref().expect("checked");
            let done = splice::run(&repo, &walker, parent, args.changed.as_deref().expect("checked"))?;
            Ok((done.snap, done.hard_links_changed))
        }
    })();
    if let Some(l) = LOCK.lock().unwrap().take() {
        l.release();
    }
    drop(lock);
    let (snap, hard_links_changed) = result?;
    // The snapshot is saved. Reload the index, which now has the new trees, to pick the sample.
    let repo = Arc::try_unwrap(repo).map_err(|_| anyhow!("repository still in use"))?;
    let repo = repo.drop_index().to_indexed_ids()?;
    summary(&out, &repo, &args.command, &snap, hard_links_changed)
}

/// No repository at the given location. Maps to exit code 10, as in restic.
#[derive(Debug)]
struct RepoMissing(String);

impl std::fmt::Display for RepoMissing {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "repository does not exist: {}", self.0)
    }
}

impl std::error::Error for RepoMissing {}

/// rustic returns its errors boxed; anyhow keeps them as they were.
fn rustic_error(e: &anyhow::Error) -> Option<&rustic_core::RusticError> {
    e.downcast_ref::<Box<rustic_core::RusticError>>().map(|b| &**b).or_else(|| e.downcast_ref::<rustic_core::RusticError>())
}

fn main() -> ExitCode {
    let args = match parse_args(std::env::args().skip(1).collect()) {
        Ok(a) => a,
        Err(e) => {
            eprintln!("nl-engine: {e:#}");
            return ExitCode::from(1);
        }
    };
    match run(args) {
        Ok(()) => {
            if output::ERRORS.load(Ordering::Relaxed) > 0 { ExitCode::from(3) } else { ExitCode::SUCCESS }
        }
        Err(e) if e.downcast_ref::<Locked>().is_some() => {
            eprintln!("nl-engine: {e:#}");
            ExitCode::from(11)
        }
        Err(e) if e.downcast_ref::<RepoMissing>().is_some() => {
            eprintln!("nl-engine: {e:#}");
            ExitCode::from(10)
        }
        // Exit codes as restic's: 12 for a wrong password.
        Err(e) if rustic_error(&e).is_some_and(|r| r.is_incorrect_password()) => {
            eprintln!("nl-engine: wrong password or no key found");
            ExitCode::from(12)
        }
        Err(e) => {
            let msg = match rustic_error(&e) {
                Some(r) => r.display_log(),
                None => format!("{e:#}"),
            };
            eprintln!("nl-engine: {msg}");
            ExitCode::from(1)
        }
    }
}
