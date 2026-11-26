//! Random files from a finished snapshot, for Nine Lives' restore test.

use std::{collections::HashMap, path::PathBuf};

use anyhow::Result;
use rustic_core::{
    TreeId,
    repofile::{NodeType, Tree},
};
use serde_json::{Value, json};

use crate::Repo;

const COUNT: usize = 50;
const MAX_SIZE: u64 = 20 * 1024 * 1024;
const ATTEMPTS: usize = 600;

/// A small xorshift generator; the sample needs spread, not cryptographic randomness.
struct Rng(u64);

impl Rng {
    fn new() -> Self {
        let t = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default();
        Self(t.as_nanos() as u64 ^ u64::from(std::process::id()) | 1)
    }
    fn below(&mut self, n: usize) -> usize {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        (self.0 % n as u64) as usize
    }
}

/// Up to 50 regular files of 1 byte to 20 MB, each found by a random walk down from the root.
pub fn sample(repo: &Repo, root: TreeId) -> Result<Vec<Value>> {
    let mut rng = Rng::new();
    let mut trees: HashMap<TreeId, Tree> = HashMap::new();
    let mut picked: HashMap<PathBuf, u64> = HashMap::new();
    for _ in 0..ATTEMPTS {
        if picked.len() >= COUNT {
            break;
        }
        let (mut id, mut path) = (root, PathBuf::from("/"));
        loop {
            if !trees.contains_key(&id) {
                _ = trees.insert(id, repo.get_tree(&id)?);
            }
            let candidates: Vec<_> = trees[&id]
                .nodes
                .iter()
                .filter(|n| {
                    n.is_dir() && n.subtree.is_some()
                        || n.node_type == NodeType::File && (1..=MAX_SIZE).contains(&n.meta.size)
                })
                .collect();
            if candidates.is_empty() {
                break;
            }
            let n = candidates[rng.below(candidates.len())];
            path.push(n.name());
            if n.is_dir() {
                id = n.subtree.expect("filtered");
            } else {
                _ = picked.insert(path, n.meta.size);
                break;
            }
        }
    }
    let mut out: Vec<_> = picked.into_iter().collect();
    out.sort();
    Ok(out
        .into_iter()
        .map(|(p, size)| json!({"path": p.to_string_lossy(), "size": size}))
        .collect())
}
