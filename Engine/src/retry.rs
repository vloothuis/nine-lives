//! Retries for reads that fail because the Mac is busy: an interrupted system call, or no free
//! file handles. Other errors are returned at once.

use std::{
    sync::atomic::{AtomicU64, Ordering},
    time::Duration,
};

const TRIES: u32 = 5;
const FIRST_WAIT_MS: u64 = 50;
/// The most time one run spends waiting for file handles. After that, busy reads fail at once.
const WAIT_BUDGET_MS: u64 = 30_000;

static WAITED_MS: AtomicU64 = AtomicU64::new(0);

/// True for errors that may go away when the same call is made again.
pub fn is_busy(e: &std::io::Error) -> bool {
    e.kind() == std::io::ErrorKind::Interrupted || is_out_of_handles(e)
}

fn is_out_of_handles(e: &std::io::Error) -> bool {
    matches!(e.raw_os_error(), Some(libc::EMFILE | libc::ENFILE))
}

/// Calls `f` again while it fails with a busy error, up to `TRIES` times in all.
/// An interrupted call is retried at once. When file handles run out, it waits 50 ms, then
/// twice as long each time, within the run's wait budget.
pub fn io<T>(mut f: impl FnMut() -> std::io::Result<T>) -> std::io::Result<T> {
    let mut wait = FIRST_WAIT_MS;
    let mut tries = 1;
    loop {
        match f() {
            Err(e) if tries < TRIES && is_busy(&e) => {
                if is_out_of_handles(&e) {
                    if WAITED_MS.fetch_add(wait, Ordering::Relaxed) + wait > WAIT_BUDGET_MS {
                        return Err(e);
                    }
                    std::thread::sleep(Duration::from_millis(wait));
                    wait *= 2;
                }
                tries += 1;
            }
            r => return r,
        }
    }
}

/// Raises the soft limit on open files to the hard limit, as far as macOS allows one process.
/// macOS starts processes with a soft limit of 256.
pub fn raise_open_file_limit() {
    let mut lim = libc::rlimit { rlim_cur: 0, rlim_max: 0 };
    // SAFETY: `lim` is a valid rlimit for the call to fill in.
    if unsafe { libc::getrlimit(libc::RLIMIT_NOFILE, &raw mut lim) } != 0 {
        return;
    }
    // setrlimit refuses values above OPEN_MAX (10240) on macOS, even with an unlimited hard limit.
    let want = lim.rlim_max.min(10_240);
    if want > lim.rlim_cur {
        lim.rlim_cur = want;
        // SAFETY: `lim` is a valid rlimit. A failure leaves the old limit, which still works.
        _ = unsafe { libc::setrlimit(libc::RLIMIT_NOFILE, &raw const lim) };
    }
}

#[cfg(test)]
mod tests {
    use std::io::{Error, ErrorKind};

    use super::*;

    #[test]
    fn retries_interrupted_then_succeeds() {
        let mut n = 0;
        let r = io(|| {
            n += 1;
            if n < 3 { Err(Error::from(ErrorKind::Interrupted)) } else { Ok(n) }
        });
        assert_eq!(r.unwrap(), 3);
    }

    #[test]
    fn gives_up_after_tries() {
        let mut n = 0;
        let r: std::io::Result<()> = io(|| {
            n += 1;
            Err(Error::from(ErrorKind::Interrupted))
        });
        assert!(r.is_err());
        assert_eq!(n, TRIES);
    }

    #[test]
    fn other_errors_fail_at_once() {
        let mut n = 0;
        let r: std::io::Result<()> = io(|| {
            n += 1;
            Err(Error::from(ErrorKind::PermissionDenied))
        });
        assert!(r.is_err());
        assert_eq!(n, 1);
    }

    #[test]
    fn out_of_handles_is_busy() {
        assert!(is_busy(&Error::from_raw_os_error(libc::ENFILE)));
        assert!(is_busy(&Error::from_raw_os_error(libc::EMFILE)));
        assert!(!is_busy(&Error::from_raw_os_error(libc::EACCES)));
    }
}
