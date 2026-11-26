//! Raw access to repository files by path, for lock files. rustic's backends have no lock file type.
//! Also a backend wrapper that refuses to write a snapshot once the lock may be stale.

use std::{
    path::PathBuf,
    sync::Arc,
};

use anyhow::{Context, Result};
use rustic_core::{
    ErrorKind, FileType, Id, ReadBackend, RusticError, RusticResult, WriteBackend,
};

use crate::lock::State;

pub trait Store: Send + Sync {
    /// File names in a folder of the repository.
    fn list(&self, dir: &str) -> Result<Vec<String>>;
    fn read(&self, path: &str) -> Result<Vec<u8>>;
    /// Writes a file under a temporary name, then renames it, so it never appears half-written.
    fn write(&self, path: &str, data: &[u8]) -> Result<()>;
    fn remove(&self, path: &str) -> Result<()>;
}

pub struct LocalStore(pub PathBuf);

impl Store for LocalStore {
    fn list(&self, dir: &str) -> Result<Vec<String>> {
        let d = self.0.join(dir);
        let rd = match std::fs::read_dir(&d) {
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
            r => r.with_context(|| format!("listing {}", d.display()))?,
        };
        let mut out = Vec::new();
        for e in rd {
            let name = e?.file_name().to_string_lossy().into_owned();
            if !name.contains('-') && !name.starts_with('.') {
                out.push(name);
            }
        }
        Ok(out)
    }

    fn read(&self, path: &str) -> Result<Vec<u8>> {
        Ok(std::fs::read(self.0.join(path))?)
    }

    fn write(&self, path: &str, data: &[u8]) -> Result<()> {
        let dst = self.0.join(path);
        if let Some(dir) = dst.parent() {
            std::fs::create_dir_all(dir)?;
        }
        let tmp = dst.with_file_name(format!(
            "{}-tmp-{}",
            dst.file_name().unwrap().to_string_lossy(),
            std::process::id()
        ));
        std::fs::write(&tmp, data)?;
        std::fs::rename(&tmp, &dst)?;
        Ok(())
    }

    fn remove(&self, path: &str) -> Result<()> {
        Ok(std::fs::remove_file(self.0.join(path))?)
    }
}

/// Passes everything to the real backend, but refuses to write a snapshot when the lock may be stale.
#[derive(Debug)]
pub struct Guarded {
    pub inner: Arc<dyn WriteBackend>,
    pub state: Arc<State>,
}

impl ReadBackend for Guarded {
    fn location(&self) -> String {
        self.inner.location()
    }
    fn list_with_size(&self, tpe: FileType) -> RusticResult<Vec<(Id, u32)>> {
        self.inner.list_with_size(tpe)
    }
    fn list(&self, tpe: FileType) -> RusticResult<Vec<Id>> {
        self.inner.list(tpe)
    }
    fn read_full(&self, tpe: FileType, id: &Id) -> RusticResult<bytes::Bytes> {
        self.inner.read_full(tpe, id)
    }
    fn read_partial(
        &self,
        tpe: FileType,
        id: &Id,
        cacheable: bool,
        offset: u32,
        length: u32,
    ) -> RusticResult<bytes::Bytes> {
        self.inner.read_partial(tpe, id, cacheable, offset, length)
    }
    fn warmup_path(&self, tpe: FileType, id: &Id) -> String {
        self.inner.warmup_path(tpe, id)
    }
}

impl WriteBackend for Guarded {
    fn create(&self) -> RusticResult<()> {
        self.inner.create()
    }
    fn write_bytes(&self, tpe: FileType, id: &Id, cacheable: bool, buf: rustic_core::BytesList) -> RusticResult<()> {
        if tpe == FileType::Snapshot
            && let Err(e) = self.state.check()
        {
            return Err(RusticError::new(ErrorKind::Backend, "Not saving the snapshot: {reason}")
                .attach_context("reason", e.to_string()));
        }
        self.inner.write_bytes(tpe, id, cacheable, buf)
    }
    fn remove(&self, tpe: FileType, id: &Id, cacheable: bool) -> RusticResult<()> {
        self.inner.remove(tpe, id, cacheable)
    }
}
