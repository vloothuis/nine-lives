//! Lists folders the way restic's backup does: names in byte order, no links followed, and
//! restic's exclude patterns, marker files and `--one-file-system` applied to each item.
//! A sweep and a splice use the same walker, so they agree on what a folder holds.

use std::{
    ffi::OsString,
    fs::Metadata,
    os::unix::fs::MetadataExt,
    path::{Path, PathBuf},
    sync::Arc,
};

use anyhow::{Result, bail};
use rustic_core::{
    LocalSourceSaveOptions, OpenFile, ReadSource, ReadSourceEntry, RusticResult,
    repofile::{Metadata as NodeMetadata, Node, NodeType},
};

use crate::{
    filter::{Marker, PatternList},
    output::Out,
};

#[derive(Debug, Clone, Default)]
pub struct Filter {
    pub patterns: PatternList,
    pub markers: Vec<Marker>,
    pub one_file_system: bool,
}

#[derive(Debug)]
pub struct Entry {
    pub path: PathBuf,
    pub node: Node,
    pub open: Option<OpenFile>,
}

#[derive(Debug, Clone)]
pub struct Walker {
    pub filter: Arc<Filter>,
    pub out: Arc<Out>,
    save_opts: LocalSourceSaveOptions,
    /// Sorted, de-nested source folders with their device IDs.
    roots: Vec<(PathBuf, u64)>,
}

/// Makes sources absolute and clean, sorts them as paths, and drops sources inside other sources.
pub fn normalize_sources(sources: &[PathBuf]) -> Result<Vec<PathBuf>> {
    let mut out: Vec<PathBuf> = Vec::new();
    for s in sources {
        if !s.is_absolute() || !crate::is_clean(s) {
            bail!("source must be an absolute path without . or ..: {}", s.display());
        }
        out.push(s.clone());
    }
    out.sort();
    out.dedup();
    let mut kept: Vec<PathBuf> = Vec::new();
    for s in out {
        if !kept.iter().any(|k| s.starts_with(k)) {
            kept.push(s);
        }
    }
    if kept.is_empty() {
        bail!("no sources given");
    }
    Ok(kept)
}

impl Walker {
    pub fn new(filter: Arc<Filter>, out: Arc<Out>, roots: &[PathBuf]) -> Result<Self> {
        let mut r = Vec::new();
        for root in roots {
            let m = std::fs::symlink_metadata(root)
                .map_err(|e| anyhow::anyhow!("cannot read source {}: {e}", root.display()))?;
            if !m.is_dir() {
                bail!("source is not a folder: {}", root.display());
            }
            r.push((root.clone(), m.dev()));
        }
        Ok(Self { filter, out, save_opts: LocalSourceSaveOptions::default(), roots: r })
    }

    pub fn roots(&self) -> impl Iterator<Item = &PathBuf> {
        self.roots.iter().map(|r| &r.0)
    }

    fn root_device(&self, path: &Path) -> Option<u64> {
        self.roots.iter().find(|(r, _)| path.starts_with(r)).map(|r| r.1)
    }

    /// Markers present in `dir`. Problems reading a marker become warnings, as in restic.
    fn markers_in(&self, dir: &Path) -> Vec<&Marker> {
        let mut warnings = Vec::new();
        let found = self.filter.markers.iter().filter(|m| m.excludes(dir, &mut warnings)).collect();
        for w in warnings {
            self.out.warning(w);
        }
        found
    }

    /// restic's reject functions for one item in `dir`, given the markers present in `dir`.
    fn keep(&self, markers: &[&Marker], name: &OsString, path: &Path, m: &Metadata) -> bool {
        // A marker excludes everything in its folder except itself.
        if markers.iter().any(|mk| name.as_os_str() != mk.name.as_str()) {
            return false;
        }
        if self.filter.patterns.excludes(path) {
            return false;
        }
        if self.filter.one_file_system
            && let Some(dev) = self.root_device(path)
            && m.dev() != dev
        {
            // Mount points are kept as empty folders. `list` shows nothing inside them.
            return m.is_dir();
        }
        true
    }

    /// True when the folder or file at `path` would not be listed in its parent folder.
    pub fn excluded(&self, path: &Path) -> bool {
        let (Some(dir), Some(name)) = (path.parent(), path.file_name()) else { return false };
        if self.roots.iter().any(|(r, _)| r == path) {
            return false;
        }
        let m = match crate::retry::io(|| std::fs::symlink_metadata(path)) {
            Ok(m) => m,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return true,
            // Not excluded, so the listing that follows reports the error.
            Err(_) => return false,
        };
        let markers = self.markers_in(dir);
        !self.keep(&markers, &name.to_os_string(), path, &m)
    }

    /// Lists one folder: its entries in byte order, with excluded ones left out.
    /// Fails when the folder cannot be read. Unreadable entries are reported and left out.
    /// A busy error is retried by reading the folder again from the start.
    pub fn list(&self, dir: &Path) -> std::io::Result<Vec<Entry>> {
        if self.filter.one_file_system
            && let Some(dev) = self.root_device(dir)
            && crate::retry::io(|| std::fs::symlink_metadata(dir))?.dev() != dev
        {
            return Ok(Vec::new());
        }
        let mut names: Vec<OsString> = crate::retry::io(|| {
            std::fs::read_dir(dir)?.map(|e| e.map(|e| e.file_name())).collect::<Result<_, _>>()
        })?;
        names.sort();
        let markers = self.markers_in(dir);
        let mut entries = Vec::with_capacity(names.len());
        for name in names {
            let path = dir.join(&name);
            let m = match crate::retry::io(|| std::fs::symlink_metadata(&path)) {
                Ok(m) => m,
                Err(e) => {
                    // Gone since the listing: not an error, as in restic.
                    if e.kind() != std::io::ErrorKind::NotFound {
                        self.out.error(&path, e);
                    }
                    continue;
                }
            };
            if !self.keep(&markers, &name, &path, &m) {
                continue;
            }
            match self.save_opts.map_path(path.clone(), &m) {
                Ok(ReadSourceEntry { path, node, open }) => entries.push(Entry { path, node, open }),
                Err(e) => self.out.error(&path, e),
            }
        }
        Ok(entries)
    }

    /// The node of a folder itself, with the same metadata a listing of its parent gives.
    pub fn own_node(&self, dir: &Path) -> std::io::Result<Node> {
        let m = crate::retry::io(|| std::fs::symlink_metadata(dir))?;
        self.save_opts.map_path(dir.to_path_buf(), &m).map(|e| e.node).map_err(std::io::Error::other)
    }
}

/// The whole tree below the sources, for rustic's archiver.
#[derive(Debug, Clone)]
pub struct Sweep(pub Walker);

impl ReadSource for Sweep {
    type Open = OpenFile;
    type Iter = SweepIter;

    fn size(&self) -> RusticResult<Option<u64>> {
        Ok(None)
    }

    fn entries(&self) -> Self::Iter {
        SweepIter {
            walker: self.0.clone(),
            roots: self.0.roots().cloned().collect::<Vec<_>>().into_iter(),
            stack: Vec::new(),
            empty_root: None,
            last: None,
        }
    }
}

#[derive(Debug)]
pub struct SweepIter {
    walker: Walker,
    roots: std::vec::IntoIter<PathBuf>,
    stack: Vec<std::vec::IntoIter<Entry>>,
    /// The current source while nothing in it has been emitted yet.
    empty_root: Option<PathBuf>,
    /// The last path returned, to check the order the archiver needs.
    last: Option<PathBuf>,
}

impl SweepIter {
    fn next_entry(&mut self) -> Option<Entry> {
        loop {
            let Some(top) = self.stack.last_mut() else {
                // Next source. Its own node is not emitted, as in rustic's `LocalSource`.
                let root = self.roots.next()?;
                match self.walker.list(&root) {
                    Ok(children) => {
                        self.walker.out.folder(&root, children.len());
                        self.stack.push(children.into_iter());
                        self.empty_root = Some(root);
                    }
                    Err(e) => self.walker.out.error(&root, e),
                }
                continue;
            };
            let Some(entry) = top.next() else {
                _ = self.stack.pop();
                if self.stack.is_empty()
                    && let Some(root) = self.empty_root.take()
                    && let Some(name) = root.file_name()
                {
                    // rustic only makes the folders of a source on the way to an item, so a source
                    // with nothing in it would be missing. restic keeps it. This is the node rustic
                    // makes for such folders, so a splice that keeps it from the parent agrees.
                    let meta = NodeMetadata { mode: Some(0o755), ..Default::default() };
                    let node = Node::new_node(name, NodeType::Dir, meta);
                    return Some(Entry { path: root, node, open: None });
                }
                continue;
            };
            self.walker.out.item(&entry.path);
            if entry.node.is_dir() {
                // Open the folder before its node is emitted, so an unreadable folder is left out.
                match self.walker.list(&entry.path) {
                    Ok(children) => {
                        self.walker.out.folder(&entry.path, children.len());
                        self.stack.push(children.into_iter());
                    }
                    Err(e) => {
                        self.walker.out.error(&entry.path, e);
                        continue;
                    }
                }
            }
            self.empty_root = None;
            return Some(entry);
        }
    }
}

impl Iterator for SweepIter {
    type Item = RusticResult<ReadSourceEntry<OpenFile>>;

    fn next(&mut self) -> Option<Self::Item> {
        let e = self.next_entry()?;
        if let Some(last) = &self.last {
            // rustic's archiver silently builds wrong trees from out-of-order items.
            assert!(last < &e.path, "walker order broken: {} after {}", e.path.display(), last.display());
        }
        self.last = Some(e.path.clone());
        Some(Ok(ReadSourceEntry { path: e.path, node: e.node, open: e.open }))
    }
}
