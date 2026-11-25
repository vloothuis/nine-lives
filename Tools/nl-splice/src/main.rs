//! nl-splice: make a complete snapshot from a parent snapshot and a list of changed folders.
//!
//! Only the changed folders are read from disk. Every other folder keeps its tree from the parent.
//! See docs/design/rustic-spike.md for the design and the threat model.

use std::{
    collections::{BTreeMap, BTreeSet, HashMap},
    path::{Component, Path, PathBuf},
    time::Instant,
};

use anyhow::{Context, Result, anyhow, bail};
use ignore::{WalkBuilder, overrides::Override};
use rustic_backend::BackendOptions;
use rustic_core::{
    BackupOptions, Credentials, Excludes, LocalSourceSaveOptions, ParentOptions,
    PathList, Repository, RepositoryOptions, SnapshotOptions, TreeId,
    repofile::{Node, NodeType, SnapshotFile, Tree},
};
use serde_json::json;

const TEMP_TAG_PREFIX: &str = "nl-splice-temp-";

struct Args {
    repo: String,
    password_file: Option<PathBuf>,
    parent: String,
    changed: PathBuf,
    globs: Vec<String>,
    markers: Vec<String>,
}

fn parse_args() -> Result<Args> {
    let mut it = std::env::args().skip(1);
    let (mut repo, mut password_file, mut parent, mut changed) = (None, None, None, None);
    let (mut globs, mut markers) = (Vec::new(), Vec::new());
    while let Some(a) = it.next() {
        let mut val = || it.next().ok_or_else(|| anyhow!("{a} needs a value"));
        match a.as_str() {
            "--repo" => repo = Some(val()?),
            "--password-file" => password_file = Some(PathBuf::from(val()?)),
            "--parent" => parent = Some(val()?),
            "--changed" => changed = Some(PathBuf::from(val()?)),
            "--glob" => globs.push(val()?),
            "--exclude-if-present" => markers.push(val()?),
            _ => bail!("unknown argument {a}"),
        }
    }
    Ok(Args {
        repo: repo.context("--repo is required")?,
        password_file,
        parent: parent.context("--parent is required")?,
        changed: changed.context("--changed is required")?,
        globs,
        markers,
    })
}

fn password(args: &Args) -> Result<String> {
    let pw = match &args.password_file {
        Some(p) => std::fs::read_to_string(p).with_context(|| format!("reading {}", p.display()))?,
        None => std::env::var("RUSTIC_PASSWORD").context("set RUSTIC_PASSWORD or --password-file")?,
    };
    Ok(pw.trim_end_matches(['\r', '\n']).to_string())
}

type Repo = Repository<rustic_core::IndexedIdsStatus>;

fn open_repo(args: &Args, pw: &str) -> Result<Repo> {
    let backends = BackendOptions::default().repository(args.repo.clone()).to_backends()?;
    Ok(Repository::new(&RepositoryOptions::default(), &backends)?
        .open(&Credentials::password(pw))?
        .to_indexed_ids()?)
}

/// What goes into a rebuilt folder's tree.
enum Item {
    /// Complete node: unchanged file with the parent's content, symbolic link, device and so on.
    Ready(Node),
    /// File to read. The node comes from the temporary backup.
    Read(PathBuf),
    /// Folder with a rebuilt tree. The node has fresh metadata; the subtree is filled in later.
    Dir(PathBuf, Node),
}

struct Ctx {
    overrides: Override,
    markers: Vec<String>,
    save_opts: LocalSourceSaveOptions,
    errors: Vec<String>,
}

impl Ctx {
    /// Lists one folder with the same walker settings as rustic's `LocalSource`.
    /// Returns the folder's own node and its entries, sorted as rustic sorts them.
    fn list(&mut self, dir: &Path) -> Result<(Node, Vec<(PathBuf, Node)>)> {
        let mut b = WalkBuilder::new(dir);
        _ = b
            .max_depth(Some(1))
            .follow_links(false)
            .hidden(false)
            .ignore(false)
            .git_ignore(false)
            .git_exclude(false)
            .require_git(true)
            .sort_by_file_path(Path::cmp)
            .same_file_system(false)
            .overrides(self.overrides.clone());
        if !self.markers.is_empty() {
            let markers = self.markers.clone();
            _ = b.filter_entry(move |e| {
                !(e.file_type().is_some_and(|t| t.is_dir())
                    && markers.iter().any(|m| e.path().join(m).exists()))
            });
        }
        let mut own = None;
        let mut entries = Vec::new();
        for e in b.build() {
            let e = match e {
                Ok(e) => e,
                Err(err) => {
                    self.errors.push(format!("{}: {err}", dir.display()));
                    continue;
                }
            };
            let depth = e.depth();
            let path = e.path().to_path_buf();
            match self.save_opts.map_entry(e) {
                Ok(rse) if depth == 0 => own = Some(rse.node),
                Ok(rse) => entries.push((path, rse.node)),
                Err(err) => self.errors.push(format!("{}: {err}", path.display())),
            }
        }
        let own = own.ok_or_else(|| anyhow!("cannot read folder {}", dir.display()))?;
        Ok((own, entries))
    }

    fn excluded(&self, dir: &Path) -> bool {
        self.overrides.matched(dir, true).is_ignore()
            || self.markers.iter().any(|m| dir.join(m).exists())
    }
}

/// rustic's test for an unchanged file (archiver/parent.rs `is_parent`).
fn unchanged(p: &Node, n: &Node) -> bool {
    let ctime_ok = p.meta.ctime.as_ref().zip(n.meta.ctime.as_ref()).is_none_or(|(x, y)| x == y);
    let inode_ok = p.meta.inode == 0 || n.meta.inode == 0 || p.meta.inode == n.meta.inode;
    p.node_type == n.node_type && p.meta.size == n.meta.size && p.meta.mtime == n.meta.mtime && ctime_ok && inode_ok
}

fn depth(p: &Path) -> usize {
    p.components().count()
}

fn tree_id(tree: &Tree) -> Result<TreeId> {
    Ok(tree.serialize().map_err(|e| anyhow!("serializing tree: {e}"))?.1)
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
}

fn main() {
    if let Err(err) = run() {
        eprintln!("nl-splice: {err:#}");
        std::process::exit(1);
    }
}

fn run() -> Result<()> {
    let t0 = Instant::now();
    let args = parse_args()?;
    let pw = password(&args)?;
    let mut repo = open_repo(&args, &pw)?;
    let t_open = t0.elapsed();

    let parent = repo.get_snapshot_from_str(&args.parent, |_| true)?;
    let temp_tag = format!("{TEMP_TAG_PREFIX}{}", parent.hostname);

    // Leftover temporary snapshots from a crashed run of this host.
    let stale: Vec<_> = repo
        .get_matching_snapshots(|s| s.tags.contains(&temp_tag))?
        .into_iter()
        .map(|s| s.id)
        .collect();
    if !stale.is_empty() {
        repo.delete_snapshots(&stale)?;
    }

    let roots: Vec<PathBuf> = parent.paths.iter().map(PathBuf::from).collect();
    let mut old = Stored::new(parent.tree);

    // 1. Read and check the changed folders.
    let text = std::fs::read_to_string(&args.changed)
        .with_context(|| format!("reading {}", args.changed.display()))?;
    let mut excludes = Excludes::default();
    excludes.globs = args.globs.clone();
    let mut ctx = Ctx {
        overrides: excludes.as_override()?,
        markers: args.markers.clone(),
        save_opts: LocalSourceSaveOptions::default(),
        errors: Vec::new(),
    };

    let mut changed = BTreeSet::new();
    for line in text.lines().map(str::trim).filter(|l| !l.is_empty()) {
        let p = PathBuf::from(line);
        if !p.is_absolute() || p.components().any(|c| matches!(c, Component::ParentDir | Component::CurDir)) {
            bail!("changed folder must be an absolute path without . or ..: {line}");
        }
        let Some(root) = roots.iter().find(|r| p.starts_with(r)) else {
            bail!("changed folder is outside the snapshot paths: {line}");
        };
        // Go up to the nearest folder that is a folder both on disk and in the parent.
        // This covers new folders (mkdir -p), renames, deletions and folders replaced by files.
        let mut d = p.clone();
        loop {
            let on_disk = std::fs::symlink_metadata(&d).is_ok_and(|m| m.is_dir());
            if on_disk && old.subtree(&repo, &d)?.is_some() {
                break;
            }
            if &d == root {
                bail!("snapshot path {} is missing on disk or in the parent", root.display());
            }
            d = d.parent().expect("inside a snapshot path").to_path_buf();
        }
        _ = changed.insert(d);
    }

    // Changed folders that are now excluded are removed. Nothing below them is rebuilt.
    let removed: BTreeSet<PathBuf> =
        changed.iter().filter(|d| !roots.contains(d) && ctx.excluded(d)).cloned().collect();
    let rebuild: BTreeSet<PathBuf> = changed
        .iter()
        .filter(|d| !removed.iter().any(|r| d.starts_with(r)))
        .cloned()
        .collect();
    // Folders above a rebuilt or removed folder, up to `/`, that are not rebuilt themselves.
    // They get the parent's tree with some entries replaced or removed.
    let mut above: BTreeSet<PathBuf> = BTreeSet::new();
    for d in rebuild.iter().chain(&removed) {
        for a in d.ancestors().skip(1) {
            if !rebuild.contains(a) {
                _ = above.insert(a.to_path_buf());
            }
        }
    }
    let dirty = |p: &Path| rebuild.contains(p) || above.contains(p);

    // 2. Plan the trees of the rebuilt folders, and of new folders below them.
    let mut plan: BTreeMap<PathBuf, Vec<Item>> = BTreeMap::new();
    let mut own_nodes: HashMap<PathBuf, Node> = HashMap::new();
    let mut to_read: Vec<PathBuf> = Vec::new();
    let mut kept = 0usize;
    let mut queue: Vec<(PathBuf, bool)> = rebuild.iter().map(|d| (d.clone(), true)).collect();
    while let Some((dir, in_parent)) = queue.pop() {
        let (own, entries) = ctx.list(&dir)?;
        _ = own_nodes.insert(dir.clone(), own);
        let mut items = Vec::with_capacity(entries.len());
        for (path, mut node) in entries {
            let prev = if in_parent { old.node(&repo, &path)? } else { None };
            match node.node_type {
                NodeType::Dir => {
                    if dirty(&path) {
                        // Rebuilt through its own queue entry, or spliced as a folder above a change.
                    } else if let Some(p) = prev.filter(Node::is_dir) {
                        node.subtree = p.subtree;
                        items.push(Item::Ready(node));
                        continue;
                    } else {
                        queue.push((path.clone(), false));
                    }
                    items.push(Item::Dir(path, node));
                }
                NodeType::File => match prev {
                    Some(p) if unchanged(&p, &node) => {
                        node.content = p.content;
                        kept += 1;
                        items.push(Item::Ready(node));
                    }
                    _ => {
                        to_read.push(path.clone());
                        items.push(Item::Read(path));
                    }
                },
                _ => items.push(Item::Ready(node)),
            }
        }
        _ = plan.insert(dir, items);
    }
    let t_plan = t0.elapsed();

    // 3. Read new and changed files with one rustic backup into a temporary snapshot.
    let mut temp_id = None;
    let mut read_nodes: HashMap<PathBuf, Node> = HashMap::new();
    if !to_read.is_empty() {
        let mut snap = SnapshotOptions::default().to_snapshot()?;
        snap.hostname.clone_from(&parent.hostname);
        _ = snap.tags.add(temp_tag.clone());
        let opts = BackupOptions::default()
            .no_scan(true)
            .parent_opts(ParentOptions::default().force(true));
        let source = PathList::from_iter(to_read.iter().cloned()).merge();
        let temp = repo.backup(&opts, &source, snap)?;
        temp_id = Some(temp.id);
        // The backup wrote new index files; load them so its trees can be read.
        repo = open_repo(&args, &pw)?;
        let mut stored = Stored::new(temp.tree);
        for p in &to_read {
            match stored.node(&repo, p)? {
                Some(n) => _ = read_nodes.insert(p.clone(), n),
                None => ctx.errors.push(format!("{}: could not be read", p.display())),
            }
        }
    }
    let t_read = t0.elapsed();

    // 4. Build trees bottom-up, deepest folder first. IDs are computed here; trees are written in one go.
    let mut new_trees: Vec<Tree> = Vec::new();
    let mut built: HashMap<PathBuf, TreeId> = HashMap::new();
    let mut order: Vec<PathBuf> = plan.keys().chain(&above).cloned().collect();
    order.sort_by_key(|p| std::cmp::Reverse(depth(p)));
    let mut folders_rebuilt = 0usize;
    for dir in order {
        let mut tree = Tree::default();
        if let Some(items) = plan.remove(&dir) {
            folders_rebuilt += 1;
            for item in items {
                match item {
                    Item::Ready(n) => tree.nodes.push(n),
                    Item::Read(p) => {
                        if let Some(n) = read_nodes.remove(&p) {
                            tree.nodes.push(n);
                        }
                    }
                    Item::Dir(p, mut n) => {
                        let id = built.get(&p).ok_or_else(|| anyhow!("no tree for {}", p.display()))?;
                        n.subtree = Some(*id);
                        tree.nodes.push(n);
                    }
                }
            }
        } else {
            // A folder above a change: the parent's tree, with changed entries replaced.
            let id = old.subtree(&repo, &dir)?.ok_or_else(|| anyhow!("{} not in parent", dir.display()))?;
            for n in &old.tree(&repo, id)?.nodes.clone() {
                let child = dir.join(n.name());
                if removed.contains(&child) {
                    continue;
                }
                let mut n = n.clone();
                if let Some(id) = built.get(&child) {
                    // Rebuilt folders get their fresh node, except snapshot paths: rustic gives
                    // those a placeholder node, so the parent's is kept.
                    if rebuild.contains(&child) && !roots.contains(&child) {
                        n = own_nodes.remove(&child).expect("listed");
                    }
                    n.subtree = Some(*id);
                }
                tree.nodes.push(n);
            }
        }
        _ = built.insert(dir, tree_id(&tree)?);
        new_trees.push(tree);
    }
    let new_root = built.get(Path::new("/")).copied().unwrap_or(parent.tree);

    // 5. Write the trees, then the snapshot.
    let tree_count = new_trees.len();
    _ = repo.save_trees(new_trees)?;
    let mut snap: SnapshotFile = parent.clone();
    snap.time = rustic_core::jiff::Zoned::now();
    snap.program_version = format!("nl-splice {}", env!("CARGO_PKG_VERSION"));
    snap.parent = Some(parent.id);
    snap.parents = vec![parent.id];
    snap.tree = new_root;
    snap.summary = None;
    snap.original = None;
    let id = repo.save_snapshot(snap)?;
    if let Some(t) = temp_id {
        repo.delete_snapshots(&[t])?;
    }

    let ms = |d: std::time::Duration| d.as_millis() as u64;
    println!(
        "{}",
        json!({
            "snapshot_id": id.to_string(),
            "parent": parent.id.to_string(),
            "folders_rebuilt": folders_rebuilt,
            "folders_removed": removed.len(),
            "files_read": to_read.len(),
            "files_kept": kept,
            "trees_written": tree_count,
            "errors": ctx.errors,
            "ms": { "open": ms(t_open), "plan": ms(t_plan), "read": ms(t_read), "total": ms(t0.elapsed()) },
        })
    );
    Ok(())
}
