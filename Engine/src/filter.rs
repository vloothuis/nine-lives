//! restic's exclude patterns, ported from restic 0.18 `internal/filter/filter.go` (BSD 2-Clause,
//! Copyright (c) 2014, Alexander Neumann). Nine Lives writes these patterns, so they must keep the
//! meaning they have in restic.
//!
//! - A pattern is split at `/`. An absolute pattern only matches from the root.
//! - A relative pattern matches at any depth.
//! - `**` matches any number of folders.
//! - A pattern also matches everything below what it matches, because only the first
//!   components of a path are compared.
//! - A pattern starting with `!` takes back the matches of the patterns before it.

use std::path::{Component, Path, PathBuf};

#[derive(Clone, Debug, PartialEq, Eq)]
struct Part {
    /// `/` for the root of an absolute pattern, empty for `**`.
    text: String,
    simple: bool,
}

#[derive(Clone, Debug)]
pub struct Pattern {
    parts: Vec<Part>,
    negated: bool,
}

/// Go's `filepath.Clean` for slash-separated paths.
fn clean(p: &str) -> String {
    if p.is_empty() {
        return ".".into();
    }
    let rooted = p.starts_with('/');
    let mut out: Vec<&str> = Vec::new();
    for c in p.split('/') {
        match c {
            "" | "." => {}
            ".." => {
                if out.last().is_some_and(|l| *l != "..") {
                    out.pop();
                } else if !rooted {
                    out.push("..");
                }
            }
            c => out.push(c),
        }
    }
    let body = out.join("/");
    match (rooted, body.is_empty()) {
        (true, _) => format!("/{body}"),
        (false, true) => ".".into(),
        (false, false) => body,
    }
}

/// Splits a cleaned path. For absolute paths the first component is `/`.
fn split(p: &str) -> Vec<String> {
    let mut parts: Vec<String> = p.split('/').map(str::to_string).collect();
    if parts[0].is_empty() {
        parts[0] = "/".into();
    }
    // "/" itself splits into ["", ""]; restic gets ["/", ""] too and never matches on it.
    parts
}

impl Pattern {
    pub fn parse(s: &str) -> Self {
        let (negated, body) = match s.strip_prefix('!') {
            Some(rest) => (true, rest),
            None => (false, s),
        };
        let parts = split(&clean(body))
            .into_iter()
            .map(|p| {
                let simple = !p.contains(['\\', '[', ']', '*', '?']);
                Part { text: if p == "**" { String::new() } else { p }, simple }
            })
            .collect();
        Self { parts, negated }
    }

    /// restic's `ValidatePatterns`: every part must be a well-formed glob.
    pub fn validate(&self) -> Result<(), BadPattern> {
        for part in &self.parts {
            glob_match(&part.text, &part.text)?;
        }
        Ok(())
    }

    fn double_wildcard(&self) -> Option<usize> {
        self.parts.iter().position(|p| p.text.is_empty())
    }
}

fn matches(parts: &[Part], strs: &[String]) -> Result<bool, BadPattern> {
    if let Some(pos) = parts.iter().position(|p| p.text.is_empty()) {
        // Expand `**` into zero, one, two ... `*` parts.
        let mut i = 0usize;
        while (i as isize) <= strs.len() as isize - parts.len() as isize + 1 {
            let mut np: Vec<Part> = parts[..pos].to_vec();
            np.extend((0..i).map(|_| Part { text: "*".into(), simple: false }));
            np.extend_from_slice(&parts[pos + 1..]);
            if matches(&np, strs)? {
                return Ok(true);
            }
            i += 1;
        }
        return Ok(false);
    }
    if parts.is_empty() {
        return Ok(strs.is_empty());
    }
    if parts.len() > strs.len() {
        return Ok(false);
    }
    let mut min = 0;
    let mut max = strs.len() - parts.len();
    if parts[0].text == "/" {
        max = 0;
    } else if strs[0] == "/" {
        min = 1;
    }
    let mut offset = max as isize;
    'outer: while offset >= min as isize {
        let o = offset as usize;
        for i in (0..parts.len()).rev() {
            let ok = if parts[i].simple {
                parts[i].text == strs[o + i]
            } else {
                glob_match(&parts[i].text, &strs[o + i])?
            };
            if !ok {
                offset -= 1;
                continue 'outer;
            }
        }
        return Ok(true);
    }
    Ok(false)
}

fn child_matches(p: &Pattern, strs: &[String]) -> Result<bool, BadPattern> {
    if p.parts[0].text != "/" {
        return Ok(true);
    }
    let mut strs = strs;
    if let Some(pos) = p.double_wildcard()
        && strs.len() >= pos
    {
        strs = &strs[..pos];
    }
    let l = strs.len().min(p.parts.len());
    matches(&p.parts[..l], strs)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BadPattern;

/// A list of patterns, applied in order as restic's `filter.List` does.
#[derive(Clone, Debug, Default)]
pub struct PatternList {
    patterns: Vec<Pattern>,
    has_negated: bool,
}

impl PatternList {
    pub fn new<S: AsRef<str>>(patterns: &[S]) -> Self {
        let patterns: Vec<Pattern> =
            patterns.iter().map(AsRef::as_ref).filter(|p| !p.is_empty()).map(Pattern::parse).collect();
        let has_negated = patterns.iter().any(|p| p.negated);
        Self { patterns, has_negated }
    }

    /// Fails on the first malformed pattern, as restic does before a backup starts.
    pub fn validate<S: AsRef<str>>(patterns: &[S]) -> Result<(), String> {
        for p in patterns.iter().map(AsRef::as_ref).filter(|p| !p.is_empty()) {
            Pattern::parse(p).validate().map_err(|_| format!("invalid exclude pattern: {p}"))?;
        }
        Ok(())
    }

    /// Returns whether the path matches, and whether something below it could still match.
    fn list(&self, path: &str, child: bool) -> Result<(bool, bool), BadPattern> {
        if self.patterns.is_empty() {
            return Ok((false, false));
        }
        if path.is_empty() {
            return Err(BadPattern);
        }
        let strs = split(path);
        let (mut matched, mut child_may) = (false, false);
        for p in &self.patterns {
            let m = matches(&p.parts, &strs)?;
            let c = if child { child_matches(p, &strs)? } else { true };
            if p.negated {
                matched = matched && !m;
                child_may = child_may && !m;
            } else {
                matched = matched || m;
                child_may = child_may || c;
                if matched && child_may && !self.has_negated {
                    break;
                }
            }
        }
        Ok((matched, child_may))
    }

    /// True when restic's `RejectByPattern` would exclude this absolute path.
    /// A malformed pattern excludes nothing, as in restic, which only warns.
    pub fn excludes(&self, path: &Path) -> bool {
        self.list(&path_str(path), false).map(|r| r.0).unwrap_or(false)
    }

    /// True when a negated pattern, a path the user chose to keep, matches this path.
    pub fn keeps(&self, path: &Path) -> bool {
        let strs = split(&path_str(path));
        self.patterns.iter().any(|p| p.negated && matches(&p.parts, &strs).unwrap_or(false))
    }

    /// `ListWithChild`. restic's backup does not use it; it is kept for the tests.
    #[cfg(test)]
    fn list_with_child(&self, path: &Path) -> Result<(bool, bool), BadPattern> {
        self.list(&path_str(path), true)
    }
}

fn path_str(p: &Path) -> String {
    // Paths come from the walker, absolute and without `.` or `..`. Bytes that are not UTF-8 are
    // replaced, so such names can only match patterns with wildcards in that place.
    let mut s = String::new();
    for c in p.components() {
        match c {
            Component::RootDir => s.push('/'),
            Component::Normal(n) => {
                if !s.is_empty() && !s.ends_with('/') {
                    s.push('/');
                }
                s.push_str(&n.to_string_lossy());
            }
            _ => {}
        }
    }
    if s.is_empty() { ".".into() } else { s }
}

/// Go's `filepath.Match` for one path component (no `/` inside).
pub fn glob_match(pattern: &str, name: &str) -> Result<bool, BadPattern> {
    let p: Vec<char> = pattern.chars().collect();
    let n: Vec<char> = name.chars().collect();
    glob(&p, &n)
}

fn glob(mut p: &[char], mut n: &[char]) -> Result<bool, BadPattern> {
    // Port of Go's Match: chunks separated by `*`, matched left to right with backtracking.
    'pattern: while !p.is_empty() {
        let mut star = false;
        while p.first() == Some(&'*') {
            p = &p[1..];
            star = true;
        }
        let (chunk, rest) = scan_chunk(p);
        p = rest;
        if star && chunk.is_empty() {
            // A trailing star matches the rest, unless it holds a `/`.
            return Ok(!n.contains(&'/'));
        }
        // Look for a match at the current position.
        let (t, ok) = match_chunk(chunk, n)?;
        if ok && (t.is_empty() || !p.is_empty()) {
            n = t;
            continue;
        }
        if star {
            // Look for a match skipping i+1 characters.
            for i in 0..n.len() {
                if n[i] == '/' {
                    break;
                }
                let (t, ok) = match_chunk(chunk, &n[i + 1..])?;
                if ok {
                    // If we are on the last chunk, it must reach the end.
                    if p.is_empty() && !t.is_empty() {
                        continue;
                    }
                    n = t;
                    continue 'pattern;
                }
            }
        }
        // Before returning false, check the rest of the pattern is well formed.
        while !p.is_empty() {
            while p.first() == Some(&'*') {
                p = &p[1..];
            }
            let (chunk, rest) = scan_chunk(p);
            p = rest;
            match_chunk(chunk, &[])?;
        }
        return Ok(false);
    }
    Ok(n.is_empty())
}

fn scan_chunk(p: &[char]) -> (&[char], &[char]) {
    let mut in_range = false;
    let mut i = 0;
    while i < p.len() {
        match p[i] {
            '\\' => {
                if i + 1 < p.len() {
                    i += 1;
                }
            }
            '[' => in_range = true,
            ']' => in_range = false,
            '*' if !in_range => break,
            _ => {}
        }
        i += 1;
    }
    (&p[..i], &p[i..])
}

/// Matches a chunk at the start of `s`. Returns the rest of `s`, or an error for a bad pattern.
fn match_chunk<'a>(mut chunk: &[char], mut s: &'a [char]) -> Result<(&'a [char], bool), BadPattern> {
    // `failed` keeps parsing after a mismatch so that a bad pattern is always reported.
    let mut failed = false;
    while !chunk.is_empty() {
        if !failed && s.is_empty() {
            failed = true;
        }
        match chunk[0] {
            '[' => {
                let r = if failed { '\0' } else { s[0] };
                if !failed {
                    s = &s[1..];
                }
                chunk = &chunk[1..];
                let negated = chunk.first() == Some(&'^');
                if negated {
                    chunk = &chunk[1..];
                }
                let mut matched = false;
                let mut n = 0;
                loop {
                    if !chunk.is_empty() && chunk[0] == ']' && n > 0 {
                        chunk = &chunk[1..];
                        break;
                    }
                    let (lo, rest) = get_esc(chunk)?;
                    chunk = rest;
                    let mut hi = lo;
                    if chunk.first() == Some(&'-') {
                        let (h, rest) = get_esc(&chunk[1..])?;
                        hi = h;
                        chunk = rest;
                    }
                    if lo <= r && r <= hi {
                        matched = true;
                    }
                    n += 1;
                }
                if matched == negated {
                    failed = true;
                }
            }
            '?' => {
                if !failed {
                    if s[0] == '/' {
                        failed = true;
                    }
                    s = &s[1..];
                }
                chunk = &chunk[1..];
            }
            '\\' => {
                chunk = &chunk[1..];
                if chunk.is_empty() {
                    return Err(BadPattern);
                }
                if !failed {
                    if chunk[0] != s[0] {
                        failed = true;
                    }
                    s = &s[1..];
                }
                chunk = &chunk[1..];
            }
            c => {
                if !failed {
                    if c != s[0] {
                        failed = true;
                    }
                    s = &s[1..];
                }
                chunk = &chunk[1..];
            }
        }
    }
    if failed { Ok((&[], false)) } else { Ok((s, true)) }
}

fn get_esc(chunk: &[char]) -> Result<(char, &[char]), BadPattern> {
    if chunk.is_empty() || chunk[0] == '-' || chunk[0] == ']' {
        return Err(BadPattern);
    }
    let mut chunk = chunk;
    if chunk[0] == '\\' {
        chunk = &chunk[1..];
        if chunk.is_empty() {
            return Err(BadPattern);
        }
    }
    let r = chunk[0];
    chunk = &chunk[1..];
    if chunk.is_empty() {
        return Err(BadPattern);
    }
    Ok((r, chunk))
}

/// A marker-file rule: `name` or `name:header`, as in restic's `--exclude-if-present`.
#[derive(Clone, Debug)]
pub struct Marker {
    pub name: String,
    pub header: Option<Vec<u8>>,
}

pub const CACHEDIR_TAG: &str = "CACHEDIR.TAG:Signature: 8a477f597d28d172789f06886806bc55";

impl Marker {
    pub fn parse(spec: &str) -> Result<Self, String> {
        match spec.find(':') {
            Some(0) => Err(format!("no name for exclusion tag file in {spec:?}")),
            Some(i) => Ok(Self { name: spec[..i].into(), header: Some(spec[i + 1..].as_bytes().to_vec()) }),
            None if spec.is_empty() => Err("name for exclusion tag file is empty".into()),
            None => Ok(Self { name: spec.into(), header: None }),
        }
    }

    /// True when `dir` holds this marker, with the right header if one is required.
    /// Problems reading a marker are returned as warnings and do not exclude the folder.
    pub fn excludes(&self, dir: &Path, warnings: &mut Vec<String>) -> bool {
        let tag: PathBuf = dir.join(&self.name);
        match std::fs::symlink_metadata(&tag) {
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return false,
            Err(e) => {
                warnings.push(format!("could not access exclusion tag file {}: {e}", tag.display()));
                return false;
            }
            Ok(_) => {}
        }
        let Some(header) = &self.header else { return true };
        if header.is_empty() {
            return true;
        }
        use std::io::Read;
        let mut buf = vec![0u8; header.len()];
        match std::fs::File::open(&tag).and_then(|mut f| f.read_exact(&mut buf)) {
            Ok(()) if &buf == header => true,
            Ok(()) => {
                warnings.push(format!("invalid signature in exclusion tag file {}", tag.display()));
                false
            }
            Err(e) => {
                warnings.push(format!("could not read signature from exclusion tag file {}: {e}", tag.display()));
                false
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// restic's `Match`.
    fn match_str(p: &str, s: &str) -> Result<bool, BadPattern> {
        if p.is_empty() {
            return Ok(true);
        }
        if s.is_empty() {
            return Err(BadPattern);
        }
        let p = Pattern::parse(p);
        matches(&p.parts, &split(s))
    }

    fn m(p: &str, s: &str) -> bool {
        match_str(p, s).unwrap()
    }

    fn res(r: Result<bool, BadPattern>) -> &'static str {
        match r {
            Ok(true) => "true",
            Ok(false) => "false",
            Err(_) => "err",
        }
    }

    /// Every case in the fixture was computed by restic 0.18.1 (see tests/filtergen).
    #[test]
    fn restic_fixture() {
        let data = include_str!("../tests/data/restic_filter_cases.tsv");
        let mut n = 0;
        for line in data.lines() {
            let f: Vec<&str> = line.split('\t').collect();
            if f[0] == "M" {
                assert_eq!(res(match_str(f[1], f[2])), f[3], "{line:?}");
            } else {
                let pats: Vec<&str> = f[1].split('\x1f').collect();
                let l = PatternList::new(&pats);
                assert_eq!(res(l.list(f[2], false).map(|r| r.0)), f[3], "{line:?}");
                let lc = l.list(f[2], true);
                assert_eq!(res(lc.map(|r| r.0)), f[4], "{line:?}");
                assert_eq!(res(lc.map(|r| r.1)), f[5], "{line:?}");
            }
            n += 1;
        }
        assert!(n > 10_000);
    }

    // Cases from restic's filter_test.go `matchTests`, plus Nine Lives patterns.
    #[test]
    fn match_cases() {
        let cases: &[(&str, &str, bool)] = &[
            ("", "", true),
            ("", "foo", true),
            ("", "/x/y/z/foo", true),
            ("*.go", "/foo/bar/test.go", true),
            ("*.c", "/foo/bar/test.go", false),
            ("*", "/foo/bar/test.go", true),
            ("**", "/foo/bar/test.go", true),
            ("foo*", "/foo/bar/test.go", true),
            ("bar*", "/foo/bar/test.go", true),
            ("/bar*", "/foo/bar/test.go", false),
            ("bar/*", "/foo/bar/test.go", true),
            ("baz/*", "/foo/bar/test.go", false),
            ("bar/test.go", "/foo/bar/test.go", true),
            ("bar/*.go", "/foo/bar/test.go", true),
            ("ba*/*.go", "/foo/bar/test.go", true),
            ("bb*/*.go", "/foo/bar/test.go", false),
            ("test.*", "/foo/bar/test.go", true),
            ("tesT.*", "/foo/bar/test.go", false),
            ("bar/*", "/foo/bar/baz", true),
            ("bar", "/foo/bar", true),
            ("/foo/bar", "/foo/bar", true),
            ("/foo/bar/", "/foo/bar", true),
            ("/foo/bar", "/foo/baz", false),
            ("/foo/bar", "/foo/baz/", false),
            ("/foo///bar", "/foo/bar", true),
            ("/foo/../bar", "/foo/bar", false),
            ("/foo/../bar", "/bar", true),
            ("/foo", "/foo/baz", true),
            ("/foo", "/foo/baz/", true),
            ("/foo/*", "/foo", false),
            ("/foo/*", "/foo/baz", true),
            ("bar", "/foo/bar/baz", true),
            ("bar", "/foo/bar/test.go", true),
            ("/foo/*test.*", "/foo/bar/test.go", false),
            ("/foo/*/test.*", "/foo/bar/test.go", true),
            ("/foo/*/bar/test.*", "/foo/bar/test.go", false),
            ("/*/*/bar/test.*", "/foo/bar/test.go", false),
            ("/*/*/bar/test.*", "/foo/bar/baz/test.go", false),
            ("/*/*/baz/test.*", "/foo/bar/baz/test.go", true),
            ("/*/foo/bar/test.*", "/foo/bar/baz/test.go", false),
            ("/*/foo/bar/test.*", "/foo/bar/baz/test.go", false),
            ("/foo/bar/test.*", "bar/baz/test.go", false),
            ("/x/y/bar/baz/test.*", "bar/baz/test.go", false),
            ("/x/y/bar/baz/test.c", "bar/baz/test.go", false),
            ("baz/test.*", "bar/baz/test.go", true),
            ("baz/tesT.*", "bar/baz/test.go", false),
            ("test.go", "bar/baz/test.go", true),
            ("*.go", "bar/baz/test.go", true),
            ("*.c", "bar/baz/test.go", false),
            ("sdk", "/foo/bar/sdk", true),
            ("sdk", "/foo/bar/sdk/test/sdk_foo.go", true),
            ("sdk/test/sdk_foo.go", "/foo/bar/sdk/test/sdk_foo.go", true),
            ("sdk/test/sdk_bar.go", "/foo/bar/sdk/test/sdk_foo.go", false),
            ("/foo/bar/sdk", "/foo/bar/sdk/test/sdk_foo.go", true),
            ("/foo/bar/sdk", "/home/user/work/go/src/github.com/foo/bar/sdk", false),
            ("foo/**/bar", "/home/user/foo/x/y/bar", true),
            ("foo/**/bar/x", "/home/user/foo/x/y/bar/x", true),
            ("foo/**/bar/x", "/home/user/foo/x/y/bar/x/y", true),
            ("foo/**/bar/x", "/home/user/foo/bar/x", true),
            ("foo/**/bar/x", "/home/user/foo/x/bar/x", true),
            ("foo/**/bar/x", "/home/user/foo/x/y/z/bar/x", true),
            ("foo/**/bar/x", "/home/user/foo/x/y/bar", false),
            ("/foo/**/bar", "/foo/bar", true),
            ("/foo/**/bar", "/foo/x/bar", true),
            ("/foo/**/bar", "/foo/x/y/z/bar", true),
            ("/foo/**/bar", "/foo/bar/baz", true),
            ("/foo/**/bar", "/foo/x/bar/baz", true),
            ("/foo/**/bar", "/x/bar", false),
            ("**/bar", "/foo/bar/baz", true),
            ("**/bar", "/foo/x/bar/baz", true),
            ("**/bar", "/foo/x/bar", true),
            ("**/bar", "/foo/bar", true),
            ("**/bar", "/x/bar", true),
            ("**/foo/bar", "/x/y/foo/bar", true),
            ("foo/**/test.go", "/foo/test.go", true),
            ("foo/**/test.go", "/x/foo/y/z/test.go", true),
            ("foo/**/test.go", "/x/foo/test.go", true),
            ("/foo/**/test.go", "/x/foo/y/z/test.go", false),
            ("**", "/foo/bar", true),
            ("**/a", "/a", true),
            ("x/**/y", "x/y", true),
            ("x/**/y", "x/a/b/c/y", true),
            // Nine Lives rules.
            (".nx/cache", "/Users/a/p/.nx/cache/x", true),
            (".nx/cache", "/Users/a/p/.nx/other", false),
            ("*.pyc", "/Users/a/p/m.pyc", true),
            ("/Users/a/Library/Caches", "/Users/a/Library/Caches/com.x/y", true),
            ("/Users/a/Library/Caches", "/Users/a/Library/CachesX", false),
            ("/Users/a/Pro\\*jects", "/Users/a/Pro*jects", true),
            ("/Users/a/Pro\\*jects", "/Users/a/Projects", false),
            ("/Users/a/[ab]x", "/Users/a/bx", true),
            ("/Users/a/[!a]x", "/Users/a/bx", false),
            ("/Users/a/[^a]x", "/Users/a/bx", true),
        ];
        for (p, s, want) in cases {
            assert_eq!(m(p, s), *want, "pattern {p:?} path {s:?}");
        }
    }

    #[test]
    fn negation() {
        let l = PatternList::new(&["*.log", "!keep.log"]);
        assert!(l.excludes(Path::new("/a/x.log")));
        assert!(!l.excludes(Path::new("/a/keep.log")));
        let l = PatternList::new(&["!keep.log", "*.log"]);
        assert!(l.excludes(Path::new("/a/keep.log")));
        // Nine Lives: a rule skips node_modules, the user keeps one of them, children included.
        let l = PatternList::new(&["node_modules", "!/Users/a/p/node_modules"]);
        assert!(l.excludes(Path::new("/Users/a/q/node_modules")));
        assert!(!l.excludes(Path::new("/Users/a/p/node_modules")));
        assert!(!l.excludes(Path::new("/Users/a/p/node_modules/x/y.js")));
    }

    #[test]
    fn child_match() {
        let l = PatternList::new(&["node_modules", "!/Users/a/p/vendor"]);
        assert!(l.keeps(Path::new("/Users/a/p/vendor")));
        assert!(!l.keeps(Path::new("/Users/a/q/vendor")));
        assert!(!l.keeps(Path::new("/Users/a/q/node_modules")), "only negated patterns keep");
        let l = PatternList::new(&["/foo/bar/*.go"]);
        assert_eq!(l.list_with_child(Path::new("/foo")).unwrap(), (false, true));
        assert_eq!(l.list_with_child(Path::new("/baz")).unwrap(), (false, false));
    }

    #[test]
    fn glob_cases() {
        // From Go's path/filepath match_test.go.
        let cases: &[(&str, &str, Result<bool, BadPattern>)] = &[
            ("abc", "abc", Ok(true)),
            ("*", "abc", Ok(true)),
            ("*c", "abc", Ok(true)),
            ("a*", "a", Ok(true)),
            ("a*", "abc", Ok(true)),
            ("a*/b", "abc/b", Ok(true)),
            ("a*b*c*d*e*/f", "axbxcxdxe/f", Ok(true)),
            ("a*b*c*d*e*/f", "axbxcxdxexxx/f", Ok(true)),
            ("a*b?c*x", "abxbbxdbxebxczzx", Ok(true)),
            ("a*b?c*x", "abxbbxdbxebxczzy", Ok(false)),
            ("ab[c]", "abc", Ok(true)),
            ("ab[b-d]", "abc", Ok(true)),
            ("ab[e-g]", "abc", Ok(false)),
            ("ab[^c]", "abc", Ok(false)),
            ("ab[^b-d]", "abc", Ok(false)),
            ("ab[^e-g]", "abc", Ok(true)),
            ("a\\*b", "a*b", Ok(true)),
            ("a\\*b", "ab", Ok(false)),
            ("a?b", "a☺b", Ok(true)),
            ("a[^a]b", "a☺b", Ok(true)),
            ("a???b", "a☺b", Ok(false)),
            ("a[^a][^a][^a]b", "a☺b", Ok(false)),
            ("[a-ζ]*", "α", Ok(true)),
            ("*[a-ζ]", "A", Ok(false)),
            ("a?b", "a/b", Ok(false)),
            ("a*b", "a/b", Ok(false)),
            ("[\\]a]", "]", Ok(true)),
            ("[\\-]", "-", Ok(true)),
            ("[x\\-]", "x", Ok(true)),
            ("[x\\-]", "-", Ok(true)),
            ("[x\\-]", "z", Ok(false)),
            ("[\\-x]", "x", Ok(true)),
            ("[\\-x]", "-", Ok(true)),
            ("[\\-x]", "a", Ok(false)),
            ("[]a]", "]", Err(BadPattern)),
            ("[-]", "-", Err(BadPattern)),
            ("[x-]", "x", Err(BadPattern)),
            ("[x-]", "-", Err(BadPattern)),
            ("[x-]", "z", Err(BadPattern)),
            ("[-x]", "x", Err(BadPattern)),
            ("[-x]", "-", Err(BadPattern)),
            ("[-x]", "a", Err(BadPattern)),
            ("\\", "a", Err(BadPattern)),
            ("[a-b-c]", "a", Err(BadPattern)),
            ("[", "a", Err(BadPattern)),
            ("[^", "a", Err(BadPattern)),
            ("[^bc", "a", Err(BadPattern)),
            ("a[", "a", Err(BadPattern)),
            ("a[", "ab", Err(BadPattern)),
            ("a[", "x", Err(BadPattern)),
            ("a/b[", "x", Err(BadPattern)),
            ("*x", "xxx", Ok(true)),
        ];
        for (p, s, want) in cases {
            assert_eq!(glob_match(p, s), *want, "pattern {p:?} name {s:?}");
        }
    }

    #[test]
    fn markers() {
        assert!(Marker::parse(":x").is_err());
        assert!(Marker::parse("").is_err());
        let m = Marker::parse(CACHEDIR_TAG).unwrap();
        assert_eq!(m.name, "CACHEDIR.TAG");
        let dir = std::env::temp_dir().join(format!("nl-engine-marker-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let mut w = Vec::new();
        assert!(!m.excludes(&dir, &mut w));
        std::fs::write(dir.join("CACHEDIR.TAG"), "Signature: wrong").unwrap();
        assert!(!m.excludes(&dir, &mut w));
        assert_eq!(w.len(), 1);
        std::fs::write(dir.join("CACHEDIR.TAG"), "Signature: 8a477f597d28d172789f06886806bc55\n# x").unwrap();
        assert!(m.excludes(&dir, &mut w));
        assert!(Marker::parse(".nobackup").unwrap().excludes(&dir, &mut w) == false);
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
