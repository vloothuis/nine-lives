//! Skips folders with a listed name when the Git repository that holds them ignores them.
//! A `.gitignore` also lists files Git must not store, such as `.env`, so the name list decides
//! what may be skipped and the `.gitignore` only confirms that a tool makes the folder.

use std::{
    collections::HashMap,
    path::{Path, PathBuf},
    sync::{Arc, Mutex, OnceLock},
};

use ignore::gitignore::{Gitignore, GitignoreBuilder};

#[derive(Debug, Default)]
pub struct GitIgnored {
    names: Vec<String>,
    /// Ignore rules per folder: its `.gitignore`, or `.git/info/exclude` for a repository root.
    files: Mutex<HashMap<PathBuf, Option<Arc<Gitignore>>>>,
    roots: Mutex<HashMap<PathBuf, Option<PathBuf>>>,
    global: OnceLock<Option<Gitignore>>,
}

impl GitIgnored {
    pub fn new(names: Vec<String>) -> Result<Self, String> {
        for n in &names {
            if n.is_empty() || n == "." || n == ".." || n.contains('/') {
                return Err(format!("invalid folder name for --exclude-gitignored: {n:?}"));
            }
        }
        Ok(Self { names, ..Self::default() })
    }

    pub fn is_empty(&self) -> bool {
        self.names.is_empty()
    }

    /// True when the folder `path`, inside `dir`, has a listed name and Git ignores it.
    pub fn excludes(&self, dir: &Path, path: &Path) -> bool {
        let Some(name) = path.file_name().and_then(|n| n.to_str()) else { return false };
        if !self.names.iter().any(|n| n == name) {
            return false;
        }
        let Some(root) = self.root(dir) else { return false };
        // The nearest .gitignore wins, as in Git.
        for a in dir.ancestors() {
            if let Some(gi) = self.load(a, a.join(".gitignore")) {
                let m = matched(&gi, path);
                if m.is_ignore() {
                    return true;
                }
                if m.is_whitelist() {
                    return false;
                }
            }
            if a == root {
                break;
            }
        }
        let info = root.join(".git/info/exclude");
        if let Some(gi) = self.load(&root.join(".git/info"), info) {
            let m = matched(&gi, path);
            if !m.is_none() {
                return m.is_ignore();
            }
        }
        let global = self.global.get_or_init(|| {
            // Rooted at `/`, so its unanchored patterns match at any depth, as in Git.
            let file = ignore::gitignore::gitconfig_excludes_path()?;
            let mut b = GitignoreBuilder::new("/");
            _ = b.add(file);
            b.build().ok().filter(|g| !g.is_empty())
        });
        global.as_ref().is_some_and(|g| matched(g, path).is_ignore())
    }

    /// The nearest folder at or above `dir` that holds `.git`.
    fn root(&self, dir: &Path) -> Option<PathBuf> {
        if let Some(r) = self.roots.lock().unwrap().get(dir) {
            return r.clone();
        }
        let r = dir.ancestors().find(|a| std::fs::symlink_metadata(a.join(".git")).is_ok()).map(Path::to_path_buf);
        self.roots.lock().unwrap().insert(dir.to_path_buf(), r.clone());
        r
    }

    /// Rules from `file`, relative to the repository folder that `key` stands for. Bad lines are
    /// skipped, as Git does. A file that cannot be read gives no rules.
    fn load(&self, key: &Path, file: PathBuf) -> Option<Arc<Gitignore>> {
        if let Some(g) = self.files.lock().unwrap().get(key) {
            return g.clone();
        }
        let g = file.is_file().then(|| {
            // .git/info/exclude applies from the repository root, two levels up.
            let base = if key.ends_with(".git/info") { key.parent()?.parent()? } else { key };
            let mut b = GitignoreBuilder::new(base);
            _ = b.add(&file);
            b.build().ok().map(Arc::new)
        });
        let g = g.flatten();
        self.files.lock().unwrap().insert(key.to_path_buf(), g.clone());
        g
    }
}

/// Git's answer for the folder `path`, or else for the nearest parent folder that has one.
/// Only folders inside the ignore file's own folder are checked, so this never panics.
fn matched(gi: &Gitignore, path: &Path) -> ignore::Match<()> {
    for p in path.ancestors() {
        match p.strip_prefix(gi.path()) {
            Ok(r) if !r.as_os_str().is_empty() => {}
            _ => break,
        }
        match gi.matched(p, true) {
            ignore::Match::None => {}
            ignore::Match::Ignore(_) => return ignore::Match::Ignore(()),
            ignore::Match::Whitelist(_) => return ignore::Match::Whitelist(()),
        }
    }
    ignore::Match::None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn repo() -> tempfile_dir::Dir {
        tempfile_dir::Dir::new()
    }

    mod tempfile_dir {
        pub struct Dir(pub std::path::PathBuf);
        impl Dir {
            pub fn new() -> Self {
                let p = std::env::temp_dir().join(format!("nl-gi-{}-{}", std::process::id(), rand_suffix()));
                std::fs::create_dir_all(p.join(".git/info")).unwrap();
                Self(p.canonicalize().unwrap())
            }
        }
        impl Drop for Dir {
            fn drop(&mut self) {
                _ = std::fs::remove_dir_all(&self.0);
            }
        }
        fn rand_suffix() -> u64 {
            use std::sync::atomic::{AtomicU64, Ordering};
            static N: AtomicU64 = AtomicU64::new(0);
            N.fetch_add(1, Ordering::Relaxed)
        }
    }

    #[test]
    fn rejects_bad_names() {
        for n in ["", ".", "..", "a/b", "../x"] {
            assert!(GitIgnored::new(vec![n.into()]).is_err(), "{n:?}");
        }
    }

    #[test]
    fn listed_and_ignored() {
        let r = repo();
        let p = &r.0;
        std::fs::write(p.join(".gitignore"), "/vendor\n.env\nbuild/\n").unwrap();
        std::fs::create_dir_all(p.join("app/build")).unwrap();
        std::fs::write(p.join("app/.gitignore"), "!build\n").unwrap();
        let g = GitIgnored::new(vec!["vendor".into(), "build".into()]).unwrap();
        assert!(g.excludes(p, &p.join("vendor")));
        assert!(!g.excludes(p, &p.join(".env")), "not on the list");
        assert!(!g.excludes(&p.join("sub"), &p.join("sub/vendor")), "anchored to the root");
        assert!(g.excludes(&p.join("lib"), &p.join("lib/build")));
        assert!(!g.excludes(&p.join("app"), &p.join("app/build")), "a nearer .gitignore keeps it");
    }

    #[test]
    fn info_exclude_and_no_repo() {
        let r = repo();
        let p = &r.0;
        std::fs::write(p.join(".git/info/exclude"), "target\n").unwrap();
        let g = GitIgnored::new(vec!["target".into()]).unwrap();
        assert!(g.excludes(&p.join("x"), &p.join("x/target")));
        std::fs::remove_dir_all(p.join(".git")).unwrap();
        let g = GitIgnored::new(vec!["target".into()]).unwrap();
        assert!(!g.excludes(&p.join("x"), &p.join("x/target")), "outside a repository");
    }
}
