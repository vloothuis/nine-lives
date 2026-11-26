//! A full backup: every folder is walked, and rustic's archiver matches files with the parent.

use std::path::PathBuf;

use anyhow::Result;
use rustic_core::{
    BackupOptions, ParentOptions, SnapshotGroupCriterion, SnapshotOptions,
    repofile::SnapshotFile,
};

use crate::{Repo, walk::{Sweep, Walker}};

pub struct Done {
    pub snap: SnapshotFile,
}

pub fn run(
    repo: &Repo,
    walker: Walker,
    sources: &[PathBuf],
    host: &str,
    tags: &[String],
    parent: Option<&str>,
    force: bool,
) -> Result<Done> {
    let mut snap: SnapshotFile = SnapshotOptions::default().to_snapshot()?;
    snap.hostname = host.to_string();
    for t in tags {
        _ = snap.tags.add(t.clone());
    }
    snap.program_version = format!("nl-engine {}", env!("CARGO_PKG_VERSION"));

    // rustic would silently drop a parent whose host or paths differ, so the parent is looked up
    // by ID only, and its use is checked afterwards.
    let parent_id = match parent {
        Some(p) if !force => Some(repo.get_snapshot_from_str(p, |_| true)?.id),
        _ => None,
    };
    let mut parent_opts = ParentOptions::default().group_by(SnapshotGroupCriterion::new());
    parent_opts = match parent_id {
        Some(id) => parent_opts.parents(vec![id.to_string()]),
        None => parent_opts.force(true),
    };
    let opts = BackupOptions::default().no_scan(true).parent_opts(parent_opts);

    let out = walker.out.clone();
    let snap = repo.archive(&opts, &Sweep(walker), snap, sources)?;
    out.progress();
    if parent_id.is_some() && snap.parent != parent_id {
        // Only slower: every file was read again. The snapshot itself is complete.
        out.warning("the parent snapshot was not used");
    }
    Ok(Done { snap })
}
