//! An incremental backup: a complete snapshot made from a parent snapshot and a list of changed
//! folders. Only the changed folders are read from disk. Every other folder keeps its tree from the
//! parent. A sweep of the same files gives the same root tree.
//!
//! The change file has one absolute folder path per line. A line `R <path>` means the folder and
//! everything below it (FSEvents' `MustScanSubDirs`).

use std::{
    collections::{BTreeSet, HashMap, HashSet},
    path::{Path, PathBuf},
    sync::{
        Mutex,
        atomic::{AtomicUsize, Ordering},
    },
};

use anyhow::{Context, Result, anyhow, bail};
use rustic_core::{
    OpenFile, ReadSourceOpen, TreeId,
    jiff::Zoned,
    repofile::{Node, NodeType, SnapshotFile, SnapshotSummary, Tree},
};

use crate::{Repo, walk::Walker};

/// More changed folders than this, and a sweep is faster and safer.
pub const MAX_CHANGED: usize = 200_000;

pub struct Done {
    pub snap: SnapshotFile,
    pub hard_links_changed: bool,
}

/// What goes into a rebuilt folder's tree.
enum Item {
    /// Complete node: an unchanged file with the parent's content, a link, a kept folder and so on.
    Ready(Node),
    /// A new or changed file of the given size, filled in after reading.
    Read(PathBuf, u64),
    /// A folder whose tree is built in this run. The node is fresh; the subtree is set later.
    Dir(PathBuf, Node),
}

/// rustic's test for an unchanged file (archiver/parent.rs `is_parent`).
fn unchanged(p: &Node, n: &Node) -> bool {
    let ctime_ok = p.meta.ctime.as_ref().zip(n.meta.ctime.as_ref()).is_none_or(|(x, y)| x == y);
    let inode_ok = p.meta.inode == 0 || n.meta.inode == 0 || p.meta.inode == n.meta.inode;
    p.node_type == n.node_type && p.meta.size == n.meta.size && p.meta.mtime == n.meta.mtime && ctime_ok && inode_ok
}

/// Files, bytes and folders, as counted in rustic's snapshot summary.
#[derive(Default, Clone, Copy, Debug, PartialEq, Eq)]
struct Totals {
    files: i64,
    bytes: i64,
    dirs: i64,
}

impl std::ops::AddAssign for Totals {
    fn add_assign(&mut self, o: Self) {
        self.files += o.files;
        self.bytes += o.bytes;
        self.dirs += o.dirs;
    }
}

impl std::ops::SubAssign for Totals {
    fn sub_assign(&mut self, o: Self) {
        self.files -= o.files;
        self.bytes -= o.bytes;
        self.dirs -= o.dirs;
    }
}

fn direct<'a>(nodes: impl Iterator<Item = &'a Node>) -> Totals {
    let mut t = Totals::default();
    for n in nodes {
        if !n.is_dir() {
            t.files += 1;
            if n.node_type == NodeType::File {
                t.bytes += n.meta.size as i64;
            }
        }
    }
    t
}

/// Cached view of a stored snapshot tree, looked up by absolute path.
struct Stored {
    root: TreeId,
    trees: HashMap<TreeId, Tree>,
    nodes: HashMap<PathBuf, Option<Node>>,
}

impl Stored {
    fn new(root: TreeId) -> Self {
        Self { root, trees: HashMap::new(), nodes: HashMap::new() }
    }

    fn tree(&mut self, repo: &Repo, id: TreeId) -> Result<&Tree> {
        if !self.trees.contains_key(&id) {
            let t = repo.get_tree(&id)?;
            _ = self.trees.insert(id, t);
        }
        Ok(&self.trees[&id])
    }

    /// The node at `path`, or `None` if there is none. `/` has no node.
    fn node(&mut self, repo: &Repo, path: &Path) -> Result<Option<Node>> {
        if let Some(n) = self.nodes.get(path) {
            return Ok(n.clone());
        }
        let found = match (path.parent(), path.file_name()) {
            (Some(up), Some(name)) => match self.subtree(repo, up)? {
                Some(id) => self.tree(repo, id)?.nodes.iter().find(|n| n.name() == name).cloned(),
                None => None,
            },
            _ => None,
        };
        _ = self.nodes.insert(path.to_path_buf(), found.clone());
        Ok(found)
    }

    /// Tree ID of the folder at `path`, if it is a folder.
    fn subtree(&mut self, repo: &Repo, path: &Path) -> Result<Option<TreeId>> {
        if path == Path::new("/") {
            return Ok(Some(self.root));
        }
        Ok(self.node(repo, path)?.filter(Node::is_dir).and_then(|n| n.subtree))
    }

    /// Totals of a whole stored subtree, the folder itself included.
    fn totals(&mut self, repo: &Repo, id: TreeId) -> Result<Totals> {
        let mut t = Totals { dirs: 1, ..Totals::default() };
        let nodes = self.tree(repo, id)?.nodes.clone();
        t += direct(nodes.iter());
        for n in nodes.iter().filter(|n| n.is_dir()) {
            if let Some(s) = n.subtree {
                t += self.totals(repo, s)?;
            }
        }
        Ok(t)
    }
}

struct Change {
    path: PathBuf,
    recursive: bool,
}

fn read_changes(file: &Path, roots: &[PathBuf]) -> Result<Vec<Change>> {
    let text = std::fs::read_to_string(file).with_context(|| format!("reading {}", file.display()))?;
    let mut out = Vec::new();
    let mut seen = HashSet::new();
    for line in text.lines().filter(|l| !l.is_empty()) {
        let (recursive, p) = match line.strip_prefix("R ") {
            Some(p) => (true, p),
            None => (false, line),
        };
        let p = PathBuf::from(p);
        if !p.is_absolute() || !crate::is_clean(&p) {
            bail!("changed folder must be an absolute path without . or ..: {line}");
        }
        if !roots.iter().any(|r| p.starts_with(r)) {
            bail!("changed folder is outside the sources: {line}");
        }
        if seen.insert((recursive, p.clone())) {
            out.push(Change { path: p, recursive });
        }
        if out.len() > MAX_CHANGED {
            bail!("more than {MAX_CHANGED} changed folders; run a full backup instead");
        }
    }
    Ok(out)
}

pub fn run(repo: &Repo, walker: &Walker, parent_id: &str, changes: &Path) -> Result<Done> {
    let start = Zoned::now();
    let parent = repo.get_snapshot_from_str(parent_id, |_| true)?;
    let roots: Vec<PathBuf> = walker.roots().cloned().collect();
    let mut parent_paths: Vec<PathBuf> = parent.paths.iter().map(PathBuf::from).collect();
    parent_paths.sort();
    if parent_paths != roots {
        bail!("the sources differ from the parent snapshot's paths; run a full backup instead");
    }
    let out = walker.out.clone();
    let mut old = Stored::new(parent.tree);

    // 1. Go up from each changed path to the nearest folder that is a folder both on disk and in
    //    the parent. This covers new folders, renames, deletions and folders replaced by files.
    let mut changed: BTreeSet<PathBuf> = BTreeSet::new();
    let mut recursive_roots: Vec<PathBuf> = Vec::new();
    for c in read_changes(changes, &roots)? {
        let root = roots.iter().find(|r| c.path.starts_with(r)).expect("checked");
        let mut d = c.path.clone();
        loop {
            let on_disk = std::fs::symlink_metadata(&d).is_ok_and(|m| m.is_dir());
            if on_disk && old.subtree(repo, &d)?.is_some() {
                break;
            }
            if &d == root {
                bail!("source {} is missing on disk or in the parent", root.display());
            }
            d = d.parent().expect("inside a source").to_path_buf();
        }
        if c.recursive || d != c.path {
            // A folder that replaced a missing one is read completely.
            recursive_roots.push(d.clone());
        }
        _ = changed.insert(d);
    }
    let recursive = |p: &Path| recursive_roots.iter().any(|r| p.starts_with(r));

    // 2. Changed folders that are now excluded or unreadable are removed. Nothing below them is
    //    rebuilt.
    let mut removed: BTreeSet<PathBuf> = BTreeSet::new();
    let mut listed: HashMap<PathBuf, Vec<crate::walk::Entry>> = HashMap::new();
    for d in &changed {
        if removed.iter().any(|r| d.starts_with(r)) {
            continue;
        }
        if !roots.contains(d) && walker.excluded(d) {
            _ = removed.insert(d.clone());
            continue;
        }
        match walker.list(d) {
            Ok(e) => _ = listed.insert(d.clone(), e),
            Err(e) if roots.contains(d) => bail!("cannot read source {}: {e}", d.display()),
            Err(e) => {
                out.error(d, e);
                _ = removed.insert(d.clone());
            }
        }
    }
    let rebuild: BTreeSet<PathBuf> =
        changed.iter().filter(|d| !removed.iter().any(|r| d.starts_with(r))).cloned().collect();
    // Folders above a rebuilt or removed folder that are not rebuilt themselves. They get the
    // parent's tree with some entries replaced or removed.
    let mut above: BTreeSet<PathBuf> = BTreeSet::new();
    for d in rebuild.iter().chain(&removed) {
        for a in d.ancestors().skip(1) {
            if !rebuild.contains(a) {
                _ = above.insert(a.to_path_buf());
            }
        }
    }
    let dirty = |p: &Path| rebuild.contains(p) || above.contains(p);

    // 3. Plan the trees of the rebuilt folders and of every folder below them that must be listed.
    let mut delta = Totals::default();
    let mut plan: HashMap<PathBuf, Vec<Item>> = HashMap::new();
    let mut to_read: Vec<(PathBuf, Node, Option<OpenFile>, bool)> = Vec::new();
    let mut work: Vec<(PathBuf, Vec<crate::walk::Entry>, bool)> = Vec::new();
    for d in &rebuild {
        let entries = listed.remove(d).expect("listed above");
        work.push((d.clone(), entries, true));
    }
    while let Some((dir, entries, in_parent)) = work.pop() {
        let rec = recursive(&dir);
        let mut items = Vec::with_capacity(entries.len());
        let mut new_dirs: HashSet<std::ffi::OsString> = HashSet::new();
        for e in &entries {
            if e.node.is_dir() {
                _ = new_dirs.insert(e.node.name().into_owned());
            }
        }
        delta += direct(entries.iter().map(|e| &e.node));
        if in_parent {
            let id = old.subtree(repo, &dir)?.ok_or_else(|| anyhow!("{} not in parent", dir.display()))?;
            let old_nodes = old.tree(repo, id)?.nodes.clone();
            delta -= direct(old_nodes.iter());
            for n in old_nodes.iter().filter(|n| n.is_dir()) {
                let child = dir.join(n.name());
                if (!new_dirs.contains(n.name().as_ref() as &std::ffi::OsStr) || removed.contains(&child))
                    && let Some(s) = n.subtree
                {
                    delta -= old.totals(repo, s)?;
                }
            }
        } else {
            delta.dirs += 1;
        }
        for crate::walk::Entry { path, mut node, open } in entries {
            let prev = if in_parent { old.node(repo, &path)? } else { None };
            match node.node_type {
                NodeType::Dir => {
                    if removed.contains(&path) {
                        // Excluded or unreadable now: left out, as in a sweep.
                        continue;
                    }
                    if dirty(&path) {
                        // Built through its own plan entry, or spliced as a folder above a change.
                        items.push(Item::Dir(path, node));
                        continue;
                    }
                    let prev_dir = prev.filter(Node::is_dir);
                    if !rec && let Some(p) = &prev_dir {
                        node.subtree = p.subtree;
                        items.push(Item::Ready(node));
                        continue;
                    }
                    match walker.list(&path) {
                        Ok(children) => {
                            work.push((path.clone(), children, prev_dir.is_some()));
                            items.push(Item::Dir(path, node));
                        }
                        Err(e) => {
                            out.error(&path, e);
                            if let Some(s) = prev_dir.and_then(|p| p.subtree) {
                                // The old folder is no longer in the snapshot.
                                if in_parent {
                                    delta -= old.totals(repo, s)?;
                                }
                            }
                        }
                    }
                }
                NodeType::File => match prev {
                    Some(p) if unchanged(&p, &node) => {
                        node.content = p.content;
                        items.push(Item::Ready(node));
                    }
                    p => {
                        let size = node.meta.size;
                        to_read.push((path.clone(), node, open, p.is_some()));
                        items.push(Item::Read(path, size));
                    }
                },
                _ => items.push(Item::Ready(node)),
            }
        }
        _ = plan.insert(dir, items);
    }
    for a in &above {
        if let Some(id) = old.subtree(repo, a)? {
            for n in old.tree(repo, id)?.nodes.clone() {
                if n.is_dir() && removed.contains(&a.join(n.name())) && let Some(s) = n.subtree {
                    delta -= old.totals(repo, s)?;
                }
            }
        }
    }

    // 4. Read new and changed files, in parallel. Unreadable files are reported and left out.
    let saver = repo.saver()?;
    let progress = repo.progress_bytes("backing up...");
    let next = AtomicUsize::new(0);
    let read_nodes: Mutex<HashMap<PathBuf, Node>> = Mutex::new(HashMap::new());
    let (files_new, files_changed) = (AtomicUsize::new(0), AtomicUsize::new(0));
    let hard_links = std::sync::atomic::AtomicBool::new(false);
    let jobs: Vec<Mutex<Option<(PathBuf, Node, Option<OpenFile>, bool)>>> =
        to_read.into_iter().map(|j| Mutex::new(Some(j))).collect();
    let threads = std::thread::available_parallelism().map_or(4, |n| n.get()).clamp(2, 8);
    std::thread::scope(|s| {
        for _ in 0..threads {
            _ = s.spawn(|| {
                loop {
                    let i = next.fetch_add(1, Ordering::Relaxed);
                    let Some(job) = jobs.get(i) else { return };
                    let (path, node, open, had_prev) = job.lock().unwrap().take().expect("taken once");
                    out.item(&path);
                    let links = node.meta.links;
                    let result = open
                        .ok_or_else(|| anyhow!("no file to open"))
                        .and_then(|o| o.open().map_err(|e| anyhow!("{}", e.display_log())))
                        .and_then(|r| saver.save_file(r, node, &progress).map_err(|e| anyhow!("{}", e.display_log())));
                    match result {
                        Ok((node, _size)) => {
                            if links > 1 {
                                hard_links.store(true, Ordering::Relaxed);
                            }
                            _ = if had_prev { &files_changed } else { &files_new }.fetch_add(1, Ordering::Relaxed);
                            _ = read_nodes.lock().unwrap().insert(path, node);
                        }
                        Err(e) => out.error(&path, e),
                    }
                }
            });
        }
    });
    let mut read_nodes = read_nodes.into_inner().unwrap();

    // 5. Build trees bottom-up, deepest folder first.
    let mut built: HashMap<PathBuf, TreeId> = HashMap::new();
    let mut order: Vec<PathBuf> = plan.keys().chain(&above).cloned().collect();
    order.sort_by_key(|p| std::cmp::Reverse(p.components().count()));
    for dir in order {
        let mut tree = Tree::default();
        if let Some(items) = plan.remove(&dir) {
            for item in items {
                match item {
                    Item::Ready(n) => tree.nodes.push(n),
                    Item::Read(p, size) => match read_nodes.remove(&p) {
                        Some(n) => tree.nodes.push(n),
                        None => {
                            // Not read, so not in the snapshot.
                            delta.files -= 1;
                            delta.bytes -= size as i64;
                        }
                    },
                    Item::Dir(p, mut n) => {
                        let id = built.get(&p).ok_or_else(|| anyhow!("no tree for {}", p.display()))?;
                        n.subtree = Some(*id);
                        tree.nodes.push(n);
                    }
                }
            }
        } else {
            let id = old.subtree(repo, &dir)?.ok_or_else(|| anyhow!("{} not in parent", dir.display()))?;
            for n in old.tree(repo, id)?.nodes.clone() {
                let child = dir.join(n.name());
                if removed.contains(&child) {
                    continue;
                }
                let mut n = n;
                if let Some(id) = built.get(&child) {
                    // Rebuilt folders get their fresh node, except sources: rustic gives those a
                    // placeholder node, so the parent's is kept.
                    if rebuild.contains(&child) && !roots.contains(&child) {
                        n = walker.own_node(&child).with_context(|| format!("reading {}", child.display()))?;
                    }
                    n.subtree = Some(*id);
                }
                tree.nodes.push(n);
            }
        }
        _ = built.insert(dir, saver.save_tree(&tree)?);
    }
    let new_root = built.get(Path::new("/")).copied().unwrap_or(parent.tree);

    // 6. Write the packs and the index, then the snapshot.
    let mut summary = SnapshotSummary::default();
    saver.finalize(&mut summary)?;
    let base = match &parent.summary {
        Some(s) => Totals {
            files: s.total_files_processed as i64,
            bytes: s.total_bytes_processed as i64,
            dirs: s.total_dirs_processed as i64,
        },
        None => old.totals(repo, parent.tree)?,
    };
    let mut total = base;
    total += delta;
    let files_new = files_new.load(Ordering::Relaxed) as u64;
    let files_changed = files_changed.load(Ordering::Relaxed) as u64;
    summary.files_new = files_new;
    summary.files_changed = files_changed;
    summary.total_files_processed = total.files.max(0) as u64;
    summary.total_bytes_processed = total.bytes.max(0) as u64;
    summary.total_dirs_processed = total.dirs.max(0) as u64;
    summary.files_unmodified = summary.total_files_processed.saturating_sub(files_new + files_changed);
    summary.error_count = out.errors.load(Ordering::Relaxed);
    summary.command = "nl-engine splice".into();
    let end = Zoned::now();
    summary.backup_duration = (&end - &start).total(rustic_core::jiff::Unit::Second).unwrap_or(0.0);
    summary.total_duration = summary.backup_duration;
    summary.backup_start = start;
    summary.backup_end = end.clone();

    let mut snap: SnapshotFile = parent.clone();
    snap.time = end;
    snap.program_version = format!("nl-engine {}", env!("CARGO_PKG_VERSION"));
    snap.parent = Some(parent.id);
    snap.parents = vec![parent.id];
    snap.tree = new_root;
    snap.summary = Some(summary);
    snap.original = None;
    let id = repo.save_snapshot(snap.clone())?;
    snap.id = id;
    out.progress();
    Ok(Done { snap, hard_links_changed: hard_links.load(Ordering::Relaxed) })
}
