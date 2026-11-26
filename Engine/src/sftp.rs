//! A small synchronous SFTP version 3 client and a rustic backend on top of it, with restic's file
//! layout.
//!
//! The engine runs the ssh command it gets as a JSON array, without a shell, and speaks SFTP over the
//! command's standard input and output. Requests from many threads share the connection: each request
//! has an ID, one thread reads all responses and hands each to the thread that waits for it. Writes and
//! reads of one file send many requests before waiting, so speed is not limited by round trips.

use std::{
    collections::HashMap,
    io::{BufReader, Read, Write},
    os::fd::AsRawFd,
    process::{Child, ChildStdin, Command, Stdio},
    sync::{
        Arc, Mutex,
        atomic::{AtomicU32, Ordering},
        mpsc::{self, Receiver, RecvTimeoutError, Sender},
    },
    time::{Duration, SystemTime},
};

use anyhow::{Context, Result, anyhow, bail};
use bytes::Bytes;
use rustic_core::{ALL_FILE_TYPES, BytesList, ErrorKind, FileType, Id, ReadBackend, RusticError, RusticResult, WriteBackend};

use crate::store::Store;

/// A request that gets no answer within this time ends the run.
const TIMEOUT: Duration = Duration::from_secs(120);

/// `NL_ENGINE_SFTP_TIMEOUT` (seconds) shortens the timeout for tests.
fn timeout() -> Duration {
    static T: std::sync::OnceLock<Duration> = std::sync::OnceLock::new();
    *T.get_or_init(|| {
        std::env::var("NL_ENGINE_SFTP_TIMEOUT").ok().and_then(|v| v.parse().ok()).map_or(TIMEOUT, Duration::from_secs)
    })
}
/// Requests per file that are sent before waiting for answers.
const WINDOW: usize = 32;
/// Temporary files older than this were left by a dropped connection and are removed when listed.
const TMP_MAX_AGE: Duration = Duration::from_secs(24 * 60 * 60);
/// Read and write size when the server does not say what it supports. Every server must accept it.
const DEFAULT_CHUNK: u32 = 32 * 1024;

mod msg {
    pub const INIT: u8 = 1;
    pub const VERSION: u8 = 2;
    pub const OPEN: u8 = 3;
    pub const CLOSE: u8 = 4;
    pub const READ: u8 = 5;
    pub const WRITE: u8 = 6;
    pub const FSTAT: u8 = 8;
    pub const OPENDIR: u8 = 11;
    pub const READDIR: u8 = 12;
    pub const REMOVE: u8 = 13;
    pub const MKDIR: u8 = 14;
    pub const STAT: u8 = 17;
    pub const RENAME: u8 = 18;
    pub const STATUS: u8 = 101;
    pub const HANDLE: u8 = 102;
    pub const DATA: u8 = 103;
    pub const NAME: u8 = 104;
    pub const ATTRS: u8 = 105;
    pub const EXTENDED: u8 = 200;
    pub const EXTENDED_REPLY: u8 = 201;
}

const OK: u32 = 0;
const EOF: u32 = 1;
const NO_SUCH_FILE: u32 = 2;

const READ: u32 = 0x01;
const WRITE: u32 = 0x02;
const CREAT: u32 = 0x08;
const TRUNC: u32 = 0x10;
const EXCL: u32 = 0x20;

const ATTR_SIZE: u32 = 0x01;
const ATTR_UIDGID: u32 = 0x02;
const ATTR_PERMISSIONS: u32 = 0x04;
const ATTR_ACMODTIME: u32 = 0x08;
const ATTR_EXTENDED: u32 = 0x8000_0000;

/// An error status from the server.
#[derive(Debug)]
pub struct Status {
    pub code: u32,
    pub message: String,
}

impl std::fmt::Display for Status {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "SFTP status {}: {}", self.code, self.message)
    }
}

impl std::error::Error for Status {}

fn is_status(e: &anyhow::Error, code: u32) -> bool {
    e.downcast_ref::<Status>().is_some_and(|s| s.code == code)
}

struct Packet {
    typ: u8,
    body: Vec<u8>,
    pos: usize,
}

impl Packet {
    fn u32(&mut self) -> Result<u32> {
        let b = self.body.get(self.pos..self.pos + 4).context("SFTP packet too short")?;
        self.pos += 4;
        Ok(u32::from_be_bytes(b.try_into().unwrap()))
    }
    fn u64(&mut self) -> Result<u64> {
        Ok((u64::from(self.u32()?) << 32) | u64::from(self.u32()?))
    }
    fn bytes(&mut self) -> Result<&[u8]> {
        let n = self.u32()? as usize;
        let b = self.body.get(self.pos..self.pos + n).context("SFTP packet too short")?;
        self.pos += n;
        Ok(b)
    }
    fn string(&mut self) -> Result<String> {
        Ok(String::from_utf8_lossy(self.bytes()?).into_owned())
    }
    fn attrs(&mut self) -> Result<Attrs> {
        let flags = self.u32()?;
        let mut a = Attrs::default();
        if flags & ATTR_SIZE != 0 {
            a.size = Some(self.u64()?);
        }
        if flags & ATTR_UIDGID != 0 {
            self.u32()?;
            self.u32()?;
        }
        if flags & ATTR_PERMISSIONS != 0 {
            a.permissions = Some(self.u32()?);
        }
        if flags & ATTR_ACMODTIME != 0 {
            self.u32()?;
            a.mtime = Some(self.u32()?);
        }
        if flags & ATTR_EXTENDED != 0 {
            for _ in 0..self.u32()? {
                self.bytes()?;
                self.bytes()?;
            }
        }
        Ok(a)
    }
    fn at_end(&self) -> bool {
        self.pos >= self.body.len()
    }

    /// Turns a STATUS packet into `Ok(())` for OK and an error otherwise; other packets must have
    /// type `want`.
    fn expect(mut self, want: u8) -> Result<Self> {
        if self.typ == msg::STATUS {
            let code = self.u32()?;
            let message = self.string().unwrap_or_default();
            if want == msg::STATUS && code == OK {
                return Ok(self);
            }
            return Err(Status { code, message }.into());
        }
        if self.typ != want {
            bail!("unexpected SFTP response type {} (wanted {want})", self.typ);
        }
        Ok(self)
    }
}

#[derive(Default)]
struct Attrs {
    size: Option<u64>,
    permissions: Option<u32>,
    mtime: Option<u32>,
}

impl Attrs {
    fn is_dir(&self) -> bool {
        self.permissions.is_some_and(|p| p & 0o170000 == 0o040000)
    }
    fn is_file(&self) -> bool {
        self.permissions.is_none_or(|p| p & 0o170000 == 0o100000)
    }
}

/// Builds the payload of a request.
#[derive(Default)]
struct Req(Vec<u8>);

impl Req {
    fn u32(mut self, v: u32) -> Self {
        self.0.extend_from_slice(&v.to_be_bytes());
        self
    }
    fn u64(mut self, v: u64) -> Self {
        self.0.extend_from_slice(&v.to_be_bytes());
        self
    }
    fn bytes(mut self, b: &[u8]) -> Self {
        self = self.u32(u32::try_from(b.len()).expect("SFTP field larger than 4 GiB"));
        self.0.extend_from_slice(b);
        self
    }
    fn str(self, s: &str) -> Self {
        self.bytes(s.as_bytes())
    }
}

type Waiters = Arc<Mutex<HashMap<u32, Sender<Packet>>>>;

struct Conn {
    stdin: Mutex<ChildStdin>,
    child: Mutex<Child>,
    waiters: Waiters,
    next: AtomicU32,
    /// Why the connection ended, with the last lines ssh wrote to standard error.
    dead: Arc<Mutex<Option<String>>>,
    stderr: Arc<Mutex<Vec<u8>>>,
}

impl Conn {
    fn start(argv: &[String]) -> Result<(Self, Packet)> {
        let (prog, args) = argv.split_first().context("the ssh command is empty")?;
        let mut child = Command::new(prog)
            .args(args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .with_context(|| format!("starting {prog}"))?;
        let mut stdout = BufReader::with_capacity(1 << 20, child.stdout.take().unwrap());
        let mut err = child.stderr.take().unwrap();
        let stdin = child.stdin.take().unwrap();
        // SAFETY: fcntl on a file descriptor this process owns.
        unsafe {
            let fd = stdin.as_raw_fd();
            let flags = libc::fcntl(fd, libc::F_GETFL);
            if flags < 0 || libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) < 0 {
                bail!("could not set up the pipe to ssh: {}", std::io::Error::last_os_error());
            }
        }

        let stderr = Arc::new(Mutex::new(Vec::new()));
        let tail = stderr.clone();
        _ = std::thread::spawn(move || {
            let mut buf = [0u8; 4096];
            while let Ok(n) = err.read(&mut buf) {
                if n == 0 {
                    break;
                }
                let mut t = tail.lock().unwrap();
                t.extend_from_slice(&buf[..n]);
                let len = t.len();
                if len > 4096 {
                    t.drain(..len - 4096);
                }
            }
        });

        let conn = Self {
            stdin: Mutex::new(stdin),
            child: Mutex::new(child),
            waiters: Arc::default(),
            next: AtomicU32::new(1),
            dead: Arc::default(),
            stderr,
        };

        // INIT has no request ID, and neither has its answer, so it is handled before the reader starts.
        let mut init = vec![msg::INIT];
        init.extend_from_slice(&3u32.to_be_bytes());
        conn.write_packet(&init).map_err(|e| conn.explain(e))?;
        let version = read_packet(&mut stdout).map_err(|e| conn.explain(e))?;
        if version.0 != msg::VERSION {
            bail!("the server did not answer the SFTP handshake (type {})", version.0);
        }
        let hello = Packet { typ: version.0, body: version.1, pos: 0 };

        let (waiters, dead) = (conn.waiters.clone(), conn.dead.clone());
        _ = std::thread::spawn(move || {
            let reason = loop {
                match read_packet(&mut stdout) {
                    Ok((typ, body)) => {
                        let Some(id) = body.get(..4) else { break "SFTP packet without request ID".to_string() };
                        let id = u32::from_be_bytes(id.try_into().unwrap());
                        if let Some(tx) = waiters.lock().unwrap().remove(&id) {
                            _ = tx.send(Packet { typ, body, pos: 4 });
                        }
                    }
                    Err(e) => break format!("{e:#}"),
                }
            };
            *dead.lock().unwrap() = Some(reason);
            // Dropping the senders wakes every waiting request.
            waiters.lock().unwrap().clear();
        });
        Ok((conn, hello))
    }

    /// Adds what ssh wrote to standard error, which usually says why the connection failed.
    fn explain(&self, e: anyhow::Error) -> anyhow::Error {
        let tail = String::from_utf8_lossy(&self.stderr.lock().unwrap()).trim().to_string();
        if tail.is_empty() { e } else { e.context(format!("ssh: {tail}")) }
    }

    /// Writes one packet. The pipe is non-blocking, so a server that stops reading ends the run after
    /// the timeout instead of blocking every thread that wants to send.
    fn write_packet(&self, data: &[u8]) -> Result<()> {
        let mut w = self.stdin.lock().unwrap();
        let len = u32::try_from(data.len())?.to_be_bytes();
        for mut buf in [&len[..], data] {
            let deadline = std::time::Instant::now() + timeout();
            while !buf.is_empty() {
                match w.write(buf) {
                    Ok(0) => bail!("the SFTP server closed its input"),
                    Ok(n) => buf = &buf[n..],
                    Err(e) if e.kind() == std::io::ErrorKind::Interrupted => {}
                    Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                        let left = deadline.saturating_duration_since(std::time::Instant::now());
                        let mut fd = libc::pollfd { fd: w.as_raw_fd(), events: libc::POLLOUT, revents: 0 };
                        let ms = libc::c_int::try_from(left.as_millis()).unwrap_or(libc::c_int::MAX);
                        // SAFETY: one valid pollfd.
                        if left.is_zero() || unsafe { libc::poll(&raw mut fd, 1, ms) } == 0 {
                            *self.dead.lock().unwrap() = Some("the server stopped reading requests".into());
                            _ = self.child.lock().unwrap().kill();
                            bail!("the SFTP server did not accept data within {} seconds", timeout().as_secs());
                        }
                    }
                    Err(e) => return Err(e.into()),
                }
            }
        }
        Ok(())
    }

    /// Sends a request and returns where its answer arrives.
    fn send(&self, typ: u8, payload: Req) -> Result<Receiver<Packet>> {
        let id = self.next.fetch_add(1, Ordering::Relaxed);
        let (tx, rx) = mpsc::channel();
        {
            let mut w = self.waiters.lock().unwrap();
            if let Some(reason) = self.dead.lock().unwrap().clone() {
                return Err(self.explain(anyhow!("the SFTP connection ended: {reason}")));
            }
            _ = w.insert(id, tx);
        }
        let mut data = Vec::with_capacity(payload.0.len() + 5);
        data.push(typ);
        data.extend_from_slice(&id.to_be_bytes());
        data.extend_from_slice(&payload.0);
        if let Err(e) = self.write_packet(&data) {
            _ = self.waiters.lock().unwrap().remove(&id);
            return Err(self.explain(anyhow::Error::from(e).context("the SFTP connection ended")));
        }
        Ok(rx)
    }

    fn wait(&self, rx: &Receiver<Packet>) -> Result<Packet> {
        match rx.recv_timeout(timeout()) {
            Ok(p) => Ok(p),
            Err(RecvTimeoutError::Disconnected) => {
                let reason = self.dead.lock().unwrap().clone().unwrap_or_default();
                Err(self.explain(anyhow!("the SFTP connection ended: {reason}")))
            }
            Err(RecvTimeoutError::Timeout) => {
                // A server that hangs would block every later request too.
                *self.dead.lock().unwrap() = Some("the server did not answer in time".into());
                _ = self.child.lock().unwrap().kill();
                bail!("the SFTP server did not answer within {} seconds", timeout().as_secs())
            }
        }
    }

    fn call(&self, typ: u8, payload: Req) -> Result<Packet> {
        let rx = self.send(typ, payload)?;
        self.wait(&rx)
    }
}

impl Drop for Conn {
    fn drop(&mut self) {
        // ssh stops when its standard input closes; this only cleans up one that hangs.
        let mut c = self.child.lock().unwrap();
        if matches!(c.try_wait(), Ok(None)) {
            _ = c.kill();
        }
        _ = c.wait();
    }
}

fn read_packet(r: &mut impl Read) -> Result<(u8, Vec<u8>)> {
    let mut len = [0u8; 4];
    r.read_exact(&mut len).context("reading from the SFTP server")?;
    let len = u32::from_be_bytes(len) as usize;
    if len == 0 || len > 1 << 24 {
        bail!("invalid SFTP packet length {len}");
    }
    let mut buf = vec![0u8; len];
    r.read_exact(&mut buf).context("reading from the SFTP server")?;
    let typ = buf.remove(0);
    Ok((typ, buf))
}

pub struct Sftp {
    conn: Conn,
    root: String,
    posix_rename: bool,
    fsync: bool,
    read_chunk: u32,
    write_chunk: u32,
    tmp_counter: AtomicU32,
}

/// Connects with the ssh command `argv` and opens the repository folder `repo` on the server. A
/// relative `repo` is relative to the user's home folder, as in restic.
pub fn connect(argv: &[String], repo: &str) -> Result<(Arc<dyn WriteBackend>, Arc<dyn Store>)> {
    let s = Arc::new(Sftp::connect(argv, repo)?);
    Ok((s.clone(), s))
}

impl Sftp {
    pub fn connect(argv: &[String], repo: &str) -> Result<Self> {
        let (conn, mut hello) = Conn::start(argv)?;
        let version = hello.u32()?;
        if version < 3 {
            bail!("the server speaks SFTP version {version}; version 3 is needed");
        }
        let mut ext = HashMap::new();
        while !hello.at_end() {
            let name = hello.string()?;
            let data = hello.string()?;
            _ = ext.insert(name, data);
        }
        let mut s = Self {
            conn,
            root: repo.trim_end_matches('/').to_string(),
            posix_rename: ext.contains_key("posix-rename@openssh.com"),
            fsync: ext.contains_key("fsync@openssh.com"),
            read_chunk: DEFAULT_CHUNK,
            write_chunk: DEFAULT_CHUNK,
            tmp_counter: AtomicU32::new(0),
        };
        if s.root.is_empty() {
            s.root = if repo.starts_with('/') { "/".into() } else { ".".into() };
        }
        if ext.contains_key("limits@openssh.com") {
            let mut p = s.conn.call(msg::EXTENDED, Req::default().str("limits@openssh.com"))?.expect(msg::EXTENDED_REPLY)?;
            let (_packet, read, write) = (p.u64()?, p.u64()?, p.u64()?);
            _ = p.u64()?;
            // Leave room for the packet header; never go below the size every server accepts.
            let fit = |v: u64| u32::try_from(v.min(1 << 20)).unwrap_or(DEFAULT_CHUNK).max(DEFAULT_CHUNK);
            s.read_chunk = fit(read);
            s.write_chunk = fit(write);
        }
        let attrs = s.stat(&s.root).with_context(|| format!("opening the repository folder {}", s.root))?;
        if !attrs.is_dir() {
            bail!("{} on the server is not a folder", s.root);
        }
        Ok(s)
    }

    fn full(&self, rel: &str) -> String {
        if rel.is_empty() { self.root.clone() } else { format!("{}/{rel}", self.root.trim_end_matches('/')) }
    }

    fn stat(&self, path: &str) -> Result<Attrs> {
        self.conn.call(msg::STAT, Req::default().str(path))?.expect(msg::ATTRS)?.attrs()
    }

    fn open(&self, path: &str, flags: u32, attrs: Req) -> Result<Vec<u8>> {
        let mut p = self.conn.call(msg::OPEN, Req::default().str(path).u32(flags).bytes_raw(attrs))?.expect(msg::HANDLE)?;
        Ok(p.bytes()?.to_vec())
    }

    fn close(&self, handle: &[u8]) -> Result<()> {
        self.conn.call(msg::CLOSE, Req::default().bytes(handle))?.expect(msg::STATUS)?;
        Ok(())
    }

    /// Lists a folder: names with their attributes, without `.` and `..`.
    fn read_dir(&self, path: &str) -> Result<Vec<(String, Attrs)>> {
        let mut h = self.conn.call(msg::OPENDIR, Req::default().str(path))?.expect(msg::HANDLE)?;
        let handle = h.bytes()?.to_vec();
        let mut out = Vec::new();
        let result = loop {
            let p = match self.conn.call(msg::READDIR, Req::default().bytes(&handle)).and_then(|p| p.expect(msg::NAME)) {
                Ok(p) => p,
                Err(e) if is_status(&e, EOF) => break Ok(()),
                Err(e) => break Err(e),
            };
            let mut p = p;
            let parsed = (|| -> Result<()> {
                for _ in 0..p.u32()? {
                    let name = p.string()?;
                    _ = p.bytes()?;
                    let attrs = p.attrs()?;
                    if name != "." && name != ".." {
                        out.push((name, attrs));
                    }
                }
                Ok(())
            })();
            if let Err(e) = parsed {
                break Err(e);
            }
        };
        let closed = self.close(&handle);
        result?;
        closed?;
        Ok(out)
    }

    fn read_range(&self, path: &str, offset: u64, length: Option<u64>) -> Result<Vec<u8>> {
        let mut h = self.conn.call(msg::OPEN, Req::default().str(path).u32(READ).u32(0))?.expect(msg::HANDLE)?;
        let handle = h.bytes()?.to_vec();
        let result = self.read_handle(&handle, offset, length);
        let closed = self.close(&handle);
        let data = result?;
        closed?;
        Ok(data)
    }

    /// Reads `length` bytes from `offset`, or to the end of the file, with many reads in flight.
    fn read_handle(&self, handle: &[u8], offset: u64, length: Option<u64>) -> Result<Vec<u8>> {
        let length = match length {
            Some(l) => l,
            None => {
                let size = self.conn.call(msg::FSTAT, Req::default().bytes(handle))?.expect(msg::ATTRS)?.attrs()?.size;
                size.context("the server did not report the file size")?.saturating_sub(offset)
            }
        };
        let mut data = Vec::with_capacity(usize::try_from(length)?);
        let chunk = u64::from(self.read_chunk);
        let end = offset + length;
        let mut pos = offset;
        while pos < end {
            // Send a window of reads, then collect them in order. A short read ends the window: the
            // rest is asked for again from where the data stopped.
            let mut inflight = Vec::new();
            let mut next = pos;
            while next < end && inflight.len() < WINDOW {
                let n = chunk.min(end - next);
                inflight.push((next, n, self.conn.send(msg::READ, Req::default().bytes(handle).u64(next).u32(n as u32))?));
                next += n;
            }
            let mut short = false;
            for (at, n, rx) in inflight {
                let reply = self.conn.wait(&rx)?;
                if short || at != pos {
                    continue;
                }
                match reply.expect(msg::DATA) {
                    Ok(mut p) => {
                        let got = p.bytes()?;
                        data.extend_from_slice(got);
                        pos += got.len() as u64;
                        if (got.len() as u64) < n {
                            short = true;
                        }
                    }
                    Err(e) if is_status(&e, EOF) => bail!("the file ended after {} of {length} bytes", pos - offset),
                    Err(e) => return Err(e),
                }
            }
        }
        Ok(data)
    }

    /// Writes a file under a temporary name in the same folder, then renames it, so a file only has
    /// its final name once it is complete. Creates missing folders.
    fn write_atomic(&self, rel: &str, parts: &[Bytes]) -> Result<()> {
        let path = self.full(rel);
        let tmp = format!("{path}-tmp-{}-{}", std::process::id(), self.tmp_counter.fetch_add(1, Ordering::Relaxed));
        let perm = || Req::default().u32(ATTR_PERMISSIONS).u32(0o600);
        let handle = match self.open(&tmp, WRITE | CREAT | TRUNC | EXCL, perm()) {
            Err(e) if is_status(&e, NO_SUCH_FILE) => {
                self.mkdir_all(rel.rsplit_once('/').map_or("", |(d, _)| d))?;
                self.open(&tmp, WRITE | CREAT | TRUNC | EXCL, perm())?
            }
            r => r?,
        };
        let written = self.write_handle(&handle, parts).and_then(|()| {
            if self.fsync {
                self.conn.call(msg::EXTENDED, Req::default().str("fsync@openssh.com").bytes(&handle))?.expect(msg::STATUS)?;
            }
            Ok(())
        });
        let closed = self.close(&handle);
        if let Err(e) = written.and(closed) {
            _ = self.remove_path(&tmp);
            return Err(e);
        }
        if let Err(e) = self.rename(&tmp, &path) {
            _ = self.remove_path(&tmp);
            return Err(e.context(format!("renaming {tmp}")));
        }
        Ok(())
    }

    fn write_handle(&self, handle: &[u8], parts: &[Bytes]) -> Result<()> {
        let chunk = self.write_chunk as usize;
        let mut inflight = std::collections::VecDeque::new();
        let mut offset = 0u64;
        for part in parts {
            for piece in part.chunks(chunk) {
                if inflight.len() >= WINDOW {
                    let rx = inflight.pop_front().unwrap();
                    self.conn.wait(&rx)?.expect(msg::STATUS)?;
                }
                inflight.push_back(self.conn.send(msg::WRITE, Req::default().bytes(handle).u64(offset).bytes(piece))?);
                offset += piece.len() as u64;
            }
        }
        for rx in inflight {
            self.conn.wait(&rx)?.expect(msg::STATUS)?;
        }
        Ok(())
    }

    fn rename(&self, from: &str, to: &str) -> Result<()> {
        if self.posix_rename {
            self.conn.call(msg::EXTENDED, Req::default().str("posix-rename@openssh.com").str(from).str(to))?.expect(msg::STATUS)?;
            return Ok(());
        }
        // Plain SFTP rename fails when the target exists. Repository files are named by their content
        // (except `config`, which is never rewritten), so an existing target has the same content.
        match self.conn.call(msg::RENAME, Req::default().str(from).str(to))?.expect(msg::STATUS) {
            Ok(_) => Ok(()),
            Err(e) if self.stat(to).is_ok_and(|a| a.is_file()) => {
                _ = e;
                self.remove_path(from)
            }
            Err(e) => Err(e),
        }
    }

    fn remove_path(&self, path: &str) -> Result<()> {
        self.conn.call(msg::REMOVE, Req::default().str(path))?.expect(msg::STATUS)?;
        Ok(())
    }

    fn mkdir_all(&self, rel: &str) -> Result<()> {
        let mut cur = String::new();
        for part in rel.split('/').filter(|p| !p.is_empty()) {
            cur = if cur.is_empty() { part.to_string() } else { format!("{cur}/{part}") };
            let path = self.full(&cur);
            if let Err(e) = self.conn.call(msg::MKDIR, Req::default().str(&path).u32(ATTR_PERMISSIONS).u32(0o700))?.expect(msg::STATUS) {
                if !self.stat(&path).is_ok_and(|a| a.is_dir()) {
                    return Err(e.context(format!("creating {path}")));
                }
            }
        }
        Ok(())
    }

    /// Lists the regular files in a folder of the repository, with their sizes. Removes temporary
    /// files that a dropped connection left behind long ago.
    fn list_files(&self, rel: &str) -> Result<Vec<(String, u64)>> {
        let path = self.full(rel);
        let entries = match self.read_dir(&path) {
            Err(e) if is_status(&e, NO_SUCH_FILE) => return Ok(Vec::new()),
            r => r?,
        };
        let now = SystemTime::now().duration_since(SystemTime::UNIX_EPOCH).unwrap_or_default().as_secs();
        let mut out = Vec::new();
        for (name, a) in entries {
            if name.contains("-tmp-") {
                if a.mtime.is_some_and(|m| now.saturating_sub(u64::from(m)) > TMP_MAX_AGE.as_secs()) {
                    _ = self.remove_path(&format!("{path}/{name}"));
                }
                continue;
            }
            if a.is_file() && !name.starts_with('.') {
                out.push((name, a.size.unwrap_or_default()));
            }
        }
        Ok(out)
    }
}

/// restic's layout: `config`, `keys/ID`, `snapshots/ID`, `index/ID`, `locks/ID` and `data/ID[..2]/ID`.
fn rel_path(tpe: FileType, id: &Id) -> String {
    let hex = id.to_hex();
    match tpe {
        FileType::Config => "config".into(),
        FileType::Pack => format!("data/{}/{}", &hex[..2], &*hex),
        _ => format!("{}/{}", tpe.dirname(), &*hex),
    }
}

fn backend_error(what: &'static str, e: anyhow::Error) -> Box<RusticError> {
    RusticError::with_source(ErrorKind::Backend, what, Box::<dyn std::error::Error + Send + Sync>::from(format!("{e:#}")))
}

impl ReadBackend for Sftp {
    fn location(&self) -> String {
        format!("sftp:{}", self.root)
    }

    fn list_with_size(&self, tpe: FileType) -> RusticResult<Vec<(Id, u32)>> {
        let go = || -> Result<Vec<(Id, u32)>> {
            if tpe == FileType::Config {
                return Ok(match self.stat(&self.full("config")) {
                    Ok(a) => vec![(Id::default(), u32::try_from(a.size.unwrap_or_default()).unwrap_or(u32::MAX))],
                    Err(e) if is_status(&e, NO_SUCH_FILE) => Vec::new(),
                    Err(e) => return Err(e),
                });
            }
            let mut files = Vec::new();
            if tpe == FileType::Pack {
                for (name, a) in self.read_dir(&self.full("data")).or_else(|e| if is_status(&e, NO_SUCH_FILE) { Ok(Vec::new()) } else { Err(e) })? {
                    if a.is_dir() && name.len() == 2 {
                        files.extend(self.list_files(&format!("data/{name}"))?);
                    }
                }
            } else {
                files = self.list_files(tpe.dirname())?;
            }
            Ok(files
                .into_iter()
                .filter(|(n, _)| n.len() == 64)
                .filter_map(|(n, size)| Some((n.parse::<Id>().ok()?, u32::try_from(size).unwrap_or(u32::MAX))))
                .collect())
        };
        go().map_err(|e| backend_error("Listing repository files over SFTP failed.", e))
    }

    fn read_full(&self, tpe: FileType, id: &Id) -> RusticResult<Bytes> {
        self.read_range(&self.full(&rel_path(tpe, id)), 0, None)
            .map(Bytes::from)
            .map_err(|e| backend_error("Reading a repository file over SFTP failed.", e))
    }

    fn read_partial(&self, tpe: FileType, id: &Id, _cacheable: bool, offset: u32, length: u32) -> RusticResult<Bytes> {
        self.read_range(&self.full(&rel_path(tpe, id)), offset.into(), Some(length.into()))
            .map(Bytes::from)
            .map_err(|e| backend_error("Reading part of a repository file over SFTP failed.", e))
    }

    fn warmup_path(&self, tpe: FileType, id: &Id) -> String {
        self.full(&rel_path(tpe, id))
    }
}

impl WriteBackend for Sftp {
    fn create(&self) -> RusticResult<()> {
        let go = || -> Result<()> {
            for tpe in ALL_FILE_TYPES {
                if tpe != FileType::Config {
                    self.mkdir_all(tpe.dirname())?;
                }
            }
            self.mkdir_all("locks")?;
            for i in 0u8..=255 {
                self.mkdir_all(&format!("data/{}", hex::encode([i])))?;
            }
            Ok(())
        };
        go().map_err(|e| backend_error("Creating the repository folders over SFTP failed.", e))
    }

    fn write_bytes(&self, tpe: FileType, id: &Id, _cacheable: bool, content: BytesList) -> RusticResult<()> {
        self.write_atomic(&rel_path(tpe, id), content.slice())
            .map_err(|e| backend_error("Writing a repository file over SFTP failed.", e))
    }

    fn remove(&self, tpe: FileType, id: &Id, _cacheable: bool) -> RusticResult<()> {
        self.remove_path(&self.full(&rel_path(tpe, id)))
            .map_err(|e| backend_error("Removing a repository file over SFTP failed.", e))
    }
}

impl Store for Sftp {
    fn list(&self, dir: &str) -> Result<Vec<String>> {
        Ok(self.list_files(dir)?.into_iter().map(|(n, _)| n).filter(|n| !n.contains('-')).collect())
    }
    fn read(&self, path: &str) -> Result<Vec<u8>> {
        self.read_range(&self.full(path), 0, None)
    }
    fn write(&self, path: &str, data: &[u8]) -> Result<()> {
        self.write_atomic(path, &[Bytes::copy_from_slice(data)])
    }
    fn remove(&self, path: &str) -> Result<()> {
        self.remove_path(&self.full(path))
    }
}

impl Req {
    /// Appends already encoded bytes, such as attributes.
    fn bytes_raw(mut self, other: Req) -> Self {
        self.0.extend_from_slice(&other.0);
        self
    }
}
