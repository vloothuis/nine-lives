//! Property test: after random changes to a random tree, a splice over the folders FSEvents would
//! report gives the same root tree and the same totals as a full backup with `--force`.
//!
//! Needs restic on PATH to create the repository. Set PROPTEST_CASES for more
//! cases than the default.

use std::fs;
use std::os::unix::fs::{PermissionsExt, symlink};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::OnceLock;
use std::sync::atomic::{AtomicUsize, Ordering};

use proptest::prelude::*;
use serde_json::Value;

const ENGINE: &str = env!("CARGO_BIN_EXE_nl-engine");
const PASSWORD: &str = "test";
/// Names that sort differently as strings and as paths, hit the filters, or are not ASCII.
const NAMES: &[&str] = &[
    "a", "b", "a-b", "a.txt", "ab", "café", "x.log", "keep.log", "cache", ".nobackup", "CACHEDIR.TAG", "z",
];
const CACHEDIR_TAG: &[u8] = b"Signature: 8a477f597d28d172789f06886806bc55\n";

#[derive(Debug, Clone)]
enum Op {
    Write { dir: usize, name: usize, len: usize, seed: u8 },
    Mkdir { dir: usize, name: usize },
    Remove { entry: usize },
    Rename { entry: usize, dir: usize, name: usize },
    Symlink { dir: usize, name: usize, target: usize },
    /// Rewrites a file with the same size and a new modification time.
    Rewrite { file: usize, seed: u8 },
    /// Makes a file unreadable, or readable again.
    ToggleReadable { file: usize },
}

fn op() -> impl Strategy<Value = Op> {
    let n = 0..NAMES.len();
    let i = any::<prop::sample::Index>().prop_map(|i| i.index(1 << 16));
    prop_oneof![
        4 => (i.clone(), n.clone(), 0..3000usize, any::<u8>()).prop_map(|(dir, name, len, seed)| Op::Write { dir, name, len, seed }),
        3 => (i.clone(), n.clone()).prop_map(|(dir, name)| Op::Mkdir { dir, name }),
        2 => i.clone().prop_map(|entry| Op::Remove { entry }),
        2 => (i.clone(), i.clone(), n.clone()).prop_map(|(entry, dir, name)| Op::Rename { entry, dir, name }),
        1 => (i.clone(), n.clone(), i.clone()).prop_map(|(dir, name, target)| Op::Symlink { dir, name, target }),
        2 => (i.clone(), any::<u8>()).prop_map(|(file, seed)| Op::Rewrite { file, seed }),
        1 => i.prop_map(|file| Op::ToggleReadable { file }),
    ]
}

/// All entries below `root`, in a fixed order. Unreadable folders are listed but not entered.
fn entries(root: &Path) -> Vec<PathBuf> {
    let mut out = Vec::new();
    let mut stack = vec![root.to_path_buf()];
    while let Some(d) = stack.pop() {
        let Ok(rd) = fs::read_dir(&d) else { continue };
        let mut names: Vec<PathBuf> = rd.map(|e| e.unwrap().path()).collect();
        names.sort();
        for p in names {
            if fs::symlink_metadata(&p).unwrap().is_dir() {
                stack.push(p.clone());
            }
            out.push(p);
        }
    }
    out.sort();
    out
}

fn dirs(root: &Path) -> Vec<PathBuf> {
    let mut v = vec![root.to_path_buf()];
    v.extend(entries(root).into_iter().filter(|p| fs::symlink_metadata(p).unwrap().is_dir()));
    v
}

fn files(root: &Path) -> Vec<PathBuf> {
    entries(root).into_iter().filter(|p| fs::symlink_metadata(p).unwrap().is_file()).collect()
}

fn content(len: usize, seed: u8, name: &str) -> Vec<u8> {
    if name == "CACHEDIR.TAG" {
        return CACHEDIR_TAG.to_vec();
    }
    (0..len).map(|i| seed.wrapping_add((i % 251) as u8)).collect()
}

/// Applies one change and returns the folders whose contents changed, as FSEvents reports them.
fn apply(root: &Path, op: &Op) -> Vec<PathBuf> {
    let pick = |v: Vec<PathBuf>, i: usize| if v.is_empty() { None } else { Some(v[i % v.len()].clone()) };
    let parent = |p: &Path| p.parent().unwrap().to_path_buf();
    match *op {
        Op::Write { dir, name, len, seed } => {
            let p = pick(dirs(root), dir).unwrap().join(NAMES[name]);
            if fs::symlink_metadata(&p).is_ok() {
                return vec![];
            }
            fs::write(&p, content(len, seed, NAMES[name])).unwrap();
            vec![parent(&p)]
        }
        Op::Mkdir { dir, name } => {
            let p = pick(dirs(root), dir).unwrap().join(NAMES[name]);
            if fs::symlink_metadata(&p).is_ok() {
                return vec![];
            }
            fs::create_dir(&p).unwrap();
            vec![parent(&p)]
        }
        Op::Remove { entry } => {
            let Some(p) = pick(entries(root), entry) else { return vec![] };
            if fs::symlink_metadata(&p).unwrap().is_dir() {
                // FSEvents reports each folder whose contents were removed.
                let mut changed = dirs(&p);
                make_removable(&p);
                fs::remove_dir_all(&p).unwrap();
                changed.push(parent(&p));
                changed
            } else {
                fs::remove_file(&p).unwrap();
                vec![parent(&p)]
            }
        }
        Op::Rename { entry, dir, name } => {
            let Some(from) = pick(entries(root), entry) else { return vec![] };
            let to = pick(dirs(root), dir).unwrap().join(NAMES[name]);
            if to.starts_with(&from) || fs::symlink_metadata(&to).is_ok() {
                return vec![];
            }
            fs::rename(&from, &to).unwrap();
            vec![parent(&from), parent(&to)]
        }
        Op::Symlink { dir, name, target } => {
            let p = pick(dirs(root), dir).unwrap().join(NAMES[name]);
            if fs::symlink_metadata(&p).is_ok() {
                return vec![];
            }
            let t = pick(entries(root), target).map_or("missing".into(), |t| t.display().to_string());
            symlink(t, &p).unwrap();
            vec![parent(&p)]
        }
        Op::Rewrite { file, seed } => {
            let Some(p) = pick(files(root), file) else { return vec![] };
            let m = fs::metadata(&p).unwrap();
            if m.permissions().mode() & 0o400 == 0 {
                return vec![];
            }
            let old = fs::read(&p).unwrap();
            let name = p.file_name().unwrap().to_str().unwrap();
            let new = if name == "CACHEDIR.TAG" { old } else { content(old.len(), seed, name) };
            // Some file systems keep only whole seconds, so move the time on explicitly.
            fs::write(&p, new).unwrap();
            let t = m.modified().unwrap() + std::time::Duration::from_secs(2);
            fs::File::options().write(true).open(&p).unwrap().set_modified(t).unwrap();
            vec![parent(&p)]
        }
        Op::ToggleReadable { file } => {
            let Some(p) = pick(files(root), file) else { return vec![] };
            let mode = fs::metadata(&p).unwrap().permissions().mode();
            let new = if mode & 0o400 == 0 { 0o644 } else { 0o000 };
            fs::set_permissions(&p, fs::Permissions::from_mode(new)).unwrap();
            vec![parent(&p)]
        }
    }
}

fn make_removable(p: &Path) {
    for f in files(p) {
        fs::set_permissions(&f, fs::Permissions::from_mode(0o644)).unwrap();
    }
}

struct Work {
    dir: PathBuf,
    repo: PathBuf,
}

/// One repository for all cases, because creating one takes about a second.
fn work() -> &'static Work {
    static W: OnceLock<Work> = OnceLock::new();
    W.get_or_init(|| {
        let dir = fs::canonicalize(std::env::temp_dir()).unwrap().join(format!("nl-engine-props-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let repo = dir.join("repo");
        let s = Command::new("restic")
            .args(["init", "-q", "--repo"])
            .arg(&repo)
            .env("RESTIC_PASSWORD", PASSWORD)
            .status()
            .expect("restic must be on PATH for this test");
        assert!(s.success(), "restic init failed");
        Work { dir, repo }
    })
}

const FILTERS: &[&str] = &[
    "--exclude", "cache", "--exclude", "*.log", "--exclude", "!keep.log",
    "--exclude-if-present", ".nobackup", "--exclude-caches",
];

struct Summary {
    snapshot: String,
    tree: String,
    files: u64,
    bytes: u64,
}

fn engine(args: &[&str], src: &Path) -> Summary {
    let w = work();
    let out = Command::new(ENGINE)
        .args(args)
        .arg("--repo")
        .arg(&w.repo)
        .args(["--host", "props", "--cache-dir"])
        .arg(w.dir.join("cache-dir"))
        .args(FILTERS)
        .arg("--")
        .arg(src)
        .env("NL_ENGINE_PASSWORD", PASSWORD)
        .output()
        .unwrap();
    let code = out.status.code().unwrap_or(-1);
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(code == 0 || code == 3, "engine {args:?} failed with {code}: {}", String::from_utf8_lossy(&out.stderr));
    let line = stdout.lines().find(|l| l.contains("\"type\":\"summary\"")).expect("a summary line");
    let v: Value = serde_json::from_str(line).unwrap();
    Summary {
        snapshot: v["snapshot_id"].as_str().unwrap().to_string(),
        tree: v["tree"].as_str().unwrap().to_string(),
        files: v["files"].as_u64().unwrap(),
        bytes: v["bytes"].as_u64().unwrap(),
    }
}

fn case_dir() -> PathBuf {
    static N: AtomicUsize = AtomicUsize::new(0);
    let d = work().dir.join(format!("case-{}", N.fetch_add(1, Ordering::Relaxed)));
    let src = d.join("src");
    fs::create_dir_all(&src).unwrap();
    src
}

fn check(start: &[Op], rounds: &[Vec<Op>]) -> Result<(), TestCaseError> {
    let src = case_dir();
    for o in start {
        _ = apply(&src, o);
    }
    let mut parent = engine(&["backup", "--force"], &src).snapshot;
    for (round, ops) in rounds.iter().enumerate() {
        let mut changed: Vec<PathBuf> = ops.iter().flat_map(|o| apply(&src, o)).collect();
        changed.sort();
        changed.dedup();
        let list = src.parent().unwrap().join("changed");
        let text: String = changed.iter().map(|p| format!("{}\n", p.display())).collect();
        fs::write(&list, text).unwrap();
        let s = engine(&["splice", "--parent", &parent, "--changed", list.to_str().unwrap()], &src);
        let f = engine(&["backup", "--force"], &src);
        prop_assert_eq!(&s.tree, &f.tree, "root tree after round {}: splice {} and full {} of {}", round, s.snapshot, f.snapshot, src.display());
        prop_assert_eq!((s.files, s.bytes), (f.files, f.bytes), "totals after round {}", round);
        parent = s.snapshot;
    }
    make_removable(&src);
    fs::remove_dir_all(src.parent().unwrap()).unwrap();
    Ok(())
}

proptest! {
    #![proptest_config(ProptestConfig { cases: 16, max_shrink_iters: 64, max_shrink_time: 300_000, failure_persistence: None, ..ProptestConfig::default() })]

    #[test]
    fn splice_matches_full_backup(
        start in prop::collection::vec(op(), 5..40),
        rounds in prop::collection::vec(prop::collection::vec(op(), 1..8), 1..4),
    ) {
        check(&start, &rounds)?;
    }
}

/// Cases the property test found. Each must keep passing.
#[test]
fn found_cases() {
    use Op::*;
    let start = vec![
        Mkdir { dir: 0, name: 7 },
        Write { dir: 28314, name: 9, len: 2207, seed: 242 },
        Remove { entry: 20814 },
        Rename { entry: 19996, dir: 40125, name: 1 },
        Mkdir { dir: 39127, name: 5 },
    ];
    let rounds = vec![vec![Remove { entry: 15530 }]];
    check(&start, &rounds).unwrap();
}
