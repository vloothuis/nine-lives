//! JSON lines on standard output, the protocol between nl-engine and Nine Lives.

use std::{
    fmt::Display,
    io::Write,
    path::Path,
    sync::{
        Arc, Mutex,
        atomic::{AtomicU64, Ordering},
    },
    time::{Duration, Instant},
};

use rustic_core::{Progress, ProgressBars, ProgressType, RusticProgress};
use serde_json::{Value, json};

/// Errors reported in this run, for the exit code.
pub static ERRORS: AtomicU64 = AtomicU64::new(0);

const PROGRESS_EVERY: Duration = Duration::from_millis(250);

#[derive(Debug)]
pub struct Out {
    last: Mutex<(Instant, String)>,
    pub files: AtomicU64,
    pub bytes: AtomicU64,
    pub errors: AtomicU64,
    /// When false, `folder` lines are not written (a splice lists only some folders).
    pub folders: bool,
}

pub fn path_str(p: &Path) -> String {
    p.to_string_lossy().into_owned()
}

impl Out {
    pub fn new(folders: bool) -> Arc<Self> {
        Arc::new(Self {
            last: Mutex::new((Instant::now(), String::new())),
            files: AtomicU64::new(0),
            bytes: AtomicU64::new(0),
            errors: AtomicU64::new(0),
            folders,
        })
    }

    pub fn emit(&self, v: &Value) {
        let line = v.to_string();
        let mut o = std::io::stdout().lock();
        // A closed stdout means Nine Lives went away. The run still finishes cleanly.
        _ = writeln!(o, "{line}");
        _ = o.flush();
    }

    pub fn folder(&self, path: &Path, items: usize) {
        if self.folders {
            self.emit(&json!({"type": "folder", "path": path_str(path), "items": items}));
        }
    }

    /// Reports an unreadable item. The message is the cause alone, such as `Permission denied`.
    pub fn error(&self, path: &Path, message: impl Display) {
        _ = self.errors.fetch_add(1, Ordering::Relaxed);
        _ = ERRORS.fetch_add(1, Ordering::Relaxed);
        self.emit(&json!({"type": "error", "path": path_str(path), "message": reason(&message.to_string())}));
    }

    pub fn warning(&self, message: impl Display) {
        self.emit(&json!({"type": "warning", "message": message.to_string()}));
    }

    /// Counts an item the walker found, and reports progress now and then.
    pub fn item(&self, path: &Path) {
        _ = self.files.fetch_add(1, Ordering::Relaxed);
        let mut last = self.last.lock().unwrap();
        if last.0.elapsed() >= PROGRESS_EVERY {
            last.0 = Instant::now();
            last.1 = path_str(path);
            drop(last);
            self.progress();
        }
    }

    pub fn progress(&self) {
        let path = self.last.lock().unwrap().1.clone();
        self.emit(&json!({
            "type": "progress",
            "files": self.files.load(Ordering::Relaxed),
            "bytes": self.bytes.load(Ordering::Relaxed),
            "path": path,
        }));
    }
}

/// rustic's progress for the bytes it reads. Errors rustic reports become `error` lines.
#[derive(Debug, Clone)]
pub struct Bytes(pub Arc<Out>);

impl RusticProgress for Bytes {
    fn is_hidden(&self) -> bool {
        false
    }
    fn set_length(&self, _len: u64) {}
    fn set_title(&self, _title: &str) {}
    fn inc(&self, inc: u64) {
        _ = self.0.bytes.fetch_add(inc, Ordering::Relaxed);
    }
    fn finish(&self) {}
    fn error(&self, item: Option<&str>, during: &str, message: &str) {
        let path = item.unwrap_or("");
        _ = during;
        self.0.error(Path::new(path), message);
    }
}

#[derive(Debug, Clone)]
pub struct Bars(pub Arc<Out>);

impl ProgressBars for Bars {
    fn progress(&self, progress_type: ProgressType, _prefix: &str) -> Progress {
        match progress_type {
            ProgressType::Bytes => Progress::new(Bytes(self.0.clone())),
            _ => Progress::hidden(),
        }
    }
}

/// The innermost cause of an error message, without rustic's context and the `(os error N)` suffix.
pub fn reason(message: &str) -> String {
    let last = message.rsplit("caused by: ").next().unwrap_or(message).trim();
    let last = match last.rfind(" (os error ") {
        Some(i) if last.ends_with(')') => &last[..i],
        _ => last,
    };
    last.to_string()
}

#[cfg(test)]
mod tests {
    #[test]
    fn reason() {
        assert_eq!(super::reason("Permission denied (os error 13)"), "Permission denied");
        assert_eq!(
            super::reason("Failed to open file at `/x`. (kind: io): caused by: Operation not permitted (os error 1)"),
            "Operation not permitted"
        );
        assert_eq!(super::reason("not a folder"), "not a folder");
    }
}
