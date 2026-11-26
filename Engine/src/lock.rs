//! restic-format lock files, so restic's `prune`, `check` and `unlock` see that the engine works on
//! the repository. rustic itself does not lock.
//!
//! The lock is not exclusive, like the lock of `restic backup`. It is refreshed every five minutes.
//! When a refresh is missed for longer than restic's stale timeout (for example while the Mac slept),
//! another client may have pruned, so the engine must not write a snapshot any more.

use std::{
    ffi::CStr,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    },
    time::{Duration, SystemTime},
};

use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::store::Store;

/// restic treats a lock as stale after 30 minutes without refresh.
pub const STALE: Duration = Duration::from_secs(30 * 60);
const REFRESH: Duration = Duration::from_secs(5 * 60);
/// restic waits this long after writing its lock before checking for others again.
const WAIT_BEFORE_CHECK: Duration = Duration::from_millis(200);

#[derive(Debug, Serialize, Deserialize)]
pub struct LockFile {
    pub time: String,
    pub exclusive: bool,
    pub hostname: String,
    pub username: String,
    pub pid: i64,
    #[serde(default, skip_serializing_if = "is_zero")]
    pub uid: u32,
    #[serde(default, skip_serializing_if = "is_zero")]
    pub gid: u32,
}

fn is_zero(v: &u32) -> bool {
    *v == 0
}

/// Shown when another process holds an exclusive lock. Maps to exit code 11.
#[derive(Debug)]
pub struct Locked(pub String);

impl std::fmt::Display for Locked {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "repository is already locked exclusively by {}", self.0)
    }
}

impl std::error::Error for Locked {}

pub fn hostname() -> String {
    let mut buf = [0 as libc::c_char; 256];
    // SAFETY: the buffer is valid and gethostname writes at most its length.
    if unsafe { libc::gethostname(buf.as_mut_ptr(), buf.len()) } != 0 {
        return String::new();
    }
    buf[buf.len() - 1] = 0;
    // SAFETY: the buffer is NUL-terminated.
    unsafe { CStr::from_ptr(buf.as_ptr()) }.to_string_lossy().into_owned()
}

fn username() -> String {
    std::env::var("USER").unwrap_or_default()
}

fn process_alive(pid: i64) -> bool {
    let Ok(pid) = libc::pid_t::try_from(pid) else { return false };
    // SAFETY: signal 0 only checks that the process exists.
    unsafe { libc::kill(pid, 0) == 0 || *libc::__error() == libc::EPERM }
}

impl LockFile {
    fn ours() -> Self {
        Self {
            time: rustic_core::jiff::Timestamp::now().to_string(),
            exclusive: false,
            hostname: hostname(),
            username: username(),
            pid: i64::from(std::process::id()),
            // SAFETY: these calls cannot fail.
            uid: unsafe { libc::getuid() },
            gid: unsafe { libc::getgid() },
        }
    }

    /// restic's `Lock.Stale`: too old, or from a process on this host that no longer runs.
    pub fn stale(&self) -> bool {
        let Ok(t) = self.time.parse::<rustic_core::jiff::Timestamp>() else { return true };
        let age = rustic_core::jiff::Timestamp::now().duration_since(t);
        if age.as_secs() > STALE.as_secs() as i64 {
            return true;
        }
        self.hostname == hostname() && !process_alive(self.pid)
    }
}

/// Encrypts and decrypts repository files with the repository key.
pub trait Codec: Send + Sync {
    fn encode(&self, data: &[u8]) -> Result<Vec<u8>>;
    fn decode(&self, data: &[u8]) -> Result<Vec<u8>>;
}

#[derive(Debug, Default)]
pub struct State {
    /// The last time a lock file was written successfully.
    last_ok: Mutex<Option<SystemTime>>,
    lost: AtomicBool,
}

impl State {
    /// Fails when the lock may have been treated as stale by another client.
    pub fn check(&self) -> Result<()> {
        if self.lost.load(Ordering::SeqCst) {
            bail!("the repository lock could not be refreshed in time, so another process may have changed the repository");
        }
        let last = self.last_ok.lock().unwrap().context("the repository is not locked")?;
        let age = SystemTime::now().duration_since(last).unwrap_or_default();
        if age >= STALE {
            self.lost.store(true, Ordering::SeqCst);
            bail!("the repository lock is older than {} minutes, so another process may have changed the repository", STALE.as_secs() / 60);
        }
        Ok(())
    }
}

pub struct Lock {
    store: Arc<dyn Store>,
    codec: Arc<dyn Codec>,
    pub state: Arc<State>,
    current: Arc<Mutex<Option<String>>>,
    stop: Arc<AtomicBool>,
    refresher: Mutex<Option<std::thread::JoinHandle<()>>>,
}

fn path(id: &str) -> String {
    format!("locks/{id}")
}

impl Lock {
    /// Locks the repository like `restic backup` does, and starts refreshing the lock.
    pub fn acquire(store: Arc<dyn Store>, codec: Arc<dyn Codec>, state: Arc<State>) -> Result<Self> {
        let lock = Self {
            store,
            codec,
            state,
            current: Arc::new(Mutex::new(None)),
            stop: Arc::new(AtomicBool::new(false)),
            refresher: Mutex::new(None),
        };
        lock.check_others(None)?;
        lock.write()?;
        std::thread::sleep(WAIT_BEFORE_CHECK);
        let ours = lock.current.lock().unwrap().clone();
        if let Err(e) = lock.check_others(ours.as_deref()) {
            lock.release();
            return Err(e);
        }
        lock.start_refresh();
        Ok(lock)
    }

    fn check_others(&self, ours: Option<&str>) -> Result<()> {
        for id in self.store.list("locks")? {
            if Some(id.as_str()) == ours {
                continue;
            }
            // A lock that disappears or cannot be read is ignored, as in restic.
            let Ok(raw) = self.store.read(&path(&id)) else { continue };
            let Ok(plain) = self.codec.decode(&raw) else { continue };
            let Ok(other) = serde_json::from_slice::<LockFile>(&plain) else { continue };
            if other.exclusive && !other.stale() {
                return Err(Locked(format!("PID {} on {} by {}", other.pid, other.hostname, other.username)).into());
            }
        }
        Ok(())
    }

    /// Writes a new lock file, then removes the previous one.
    fn write(&self) -> Result<()> {
        write_lock(&*self.store, &*self.codec, &self.current, &self.state)
    }

    fn start_refresh(&self) {
        let (store, codec, current, state, stop) =
            (self.store.clone(), self.codec.clone(), self.current.clone(), self.state.clone(), self.stop.clone());
        let handle = std::thread::spawn(move || {
            loop {
                let mut slept = Duration::ZERO;
                while slept < REFRESH {
                    std::thread::sleep(Duration::from_secs(1));
                    slept += Duration::from_secs(1);
                    if stop.load(Ordering::SeqCst) {
                        return;
                    }
                }
                // After a long sleep of the Mac the lock may already count as stale.
                if state.check().is_err() {
                    return;
                }
                _ = write_lock(&*store, &*codec, &current, &state);
            }
        });
        *self.refresher.lock().unwrap() = Some(handle);
    }

    /// Stops refreshing and removes the lock file. Errors are ignored: a lock left behind is
    /// stale once this process has exited, and `restic unlock` removes it.
    pub fn release(&self) {
        self.stop.store(true, Ordering::SeqCst);
        if let Some(h) = self.refresher.lock().unwrap().take()
            && h.thread().id() != std::thread::current().id()
        {
            _ = h.join();
        }
        if let Some(id) = self.current.lock().unwrap().take() {
            _ = self.store.remove(&path(&id));
        }
    }
}

fn write_lock(store: &dyn Store, codec: &dyn Codec, current: &Mutex<Option<String>>, state: &State) -> Result<()> {
    let plain = serde_json::to_vec(&LockFile::ours())?;
    let data = codec.encode(&plain)?;
    let id = hex::encode(Sha256::digest(&data));
    store.write(&path(&id), &data).context("writing lock file")?;
    *state.last_ok.lock().unwrap() = Some(SystemTime::now());
    let old = current.lock().unwrap().replace(id);
    if let Some(old) = old {
        _ = store.remove(&path(&old));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stale_rules() {
        let mut l = LockFile::ours();
        assert!(!l.stale());
        l.pid = i64::from(i32::MAX);
        assert!(l.stale(), "dead process on this host");
        l.hostname = "elsewhere".into();
        assert!(!l.stale(), "other host, fresh");
        l.time = "2020-01-01T00:00:00Z".into();
        assert!(l.stale(), "old");
    }

    #[test]
    fn json_matches_restic() {
        let l = LockFile { time: "2024-01-01T00:00:00Z".into(), exclusive: true, hostname: "h".into(), username: "u".into(), pid: 7, uid: 0, gid: 20 };
        assert_eq!(
            serde_json::to_string(&l).unwrap(),
            r#"{"time":"2024-01-01T00:00:00Z","exclusive":true,"hostname":"h","username":"u","pid":7,"gid":20}"#
        );
    }
}
