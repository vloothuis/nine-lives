import Foundation

public enum ResticBinary {
    /// Finds a usable restic executable. Order: explicit override, bundled copy, Homebrew.
    public static func locate(override: String? = nil, bundleResources: URL? = Bundle.main.resourceURL) -> URL? {
        var candidates: [String] = []
        if let override, !override.isEmpty { candidates.append(override) }
        if let env = ProcessInfo.processInfo.environment["NINELIVES_RESTIC"] { candidates.append(env) }
        if let res = bundleResources { candidates.append(res.appendingPathComponent("restic").path) }
        candidates += ["/opt/homebrew/bin/restic", "/usr/local/bin/restic"]
        for c in candidates {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: c, isDirectory: &isDir), !isDir.boolValue,
               FileManager.default.isExecutableFile(atPath: c) {
                return URL(fileURLWithPath: c)
            }
        }
        return nil
    }
}

public enum ResticDate {
    /// restic prints RFC 3339 times with up to nine fractional digits.
    public static func parse(_ s: String) -> Date? {
        var text = s
        var fraction = 0.0
        if let dot = text.firstIndex(of: "."), let end = text[dot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) {
            fraction = Double("0" + text[dot..<end]) ?? 0
            text.removeSubrange(dot..<end)
        }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: text).map { $0.addingTimeInterval(fraction) }
    }
}

/// Thin, typed wrapper around the restic command line.
///
/// Every call is an independent process. Callers must make sure only one operation
/// changes a repository at a time.
public final class Restic: Sendable {
    public let binary: URL
    /// restic's cache, kept apart from any restic the user runs themselves.
    public let cacheDirectory: URL?
    public let ssh: SSHOptions?

    public init(binary: URL, cacheDirectory: URL? = nil, ssh: SSHOptions? = nil) {
        self.binary = binary
        self.cacheDirectory = cacheDirectory
        self.ssh = ssh
    }

    // MARK: - Plumbing

    func environment(password: String?) -> [String: String] {
        var env: [String: String] = [
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": NSHomeDirectory(),
            "RESTIC_PROGRESS_FPS": "4",
        ]
        if let password { env["RESTIC_PASSWORD"] = password }
        if let cacheDirectory { env["RESTIC_CACHE_DIR"] = cacheDirectory.path }
        return env
    }

    struct Execution {
        var stdout: Data
        var exit: ResticExit
        var code: Int32
        var logs: LogCollector
    }

    /// Options that select the repository.
    private func repoArgs(_ repo: ResticRepo) -> [String] {
        var a = ["-r", repo.location, "--json"]
        if let remote = repo.remote, let ssh { a += ["-o", "sftp.command=" + ssh.sftpCommand(remote)] }
        return a
    }

    func execute(
        _ args: [String],
        repo: ResticRepo?,
        workingDirectory: URL? = nil,
        onMessage: (@Sendable (ResticMessage) -> Void)? = nil,
        onStdoutLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> Execution {
        if let cacheDirectory {
            try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        }
        let logs = LogCollector()
        let handle: @Sendable (String) -> Void = { line in
            if let m = ResticMessage.parse(line) {
                logs.add(m)
                onMessage?(m)
            } else {
                logs.addRaw(line)
            }
        }
        var stdoutHandler: (@Sendable (String) -> Void)? = onStdoutLine
        if stdoutHandler == nil, onMessage != nil { stdoutHandler = handle }
        let fullArgs: [String] = (repo.map { repoArgs($0) } ?? []) + args
        let result = try await ProcessRunner.run(
            executable: binary,
            arguments: fullArgs,
            environment: environment(password: repo?.password),
            currentDirectory: workingDirectory,
            onStdoutLine: stdoutHandler,
            onStderrLine: handle
        )
        return Execution(stdout: result.stdout, exit: ResticExit(code: result.exitCode), code: result.exitCode, logs: logs)
    }

    /// Like `execute`, but throws on failure and cancellation.
    func executeChecked(
        _ args: [String],
        repo: ResticRepo?,
        workingDirectory: URL? = nil,
        onMessage: (@Sendable (ResticMessage) -> Void)? = nil,
        onStdoutLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> Execution {
        let e = try await execute(args, repo: repo, workingDirectory: workingDirectory, onMessage: onMessage, onStdoutLine: onStdoutLine)
        switch e.exit {
        case .success, .warning: return e
        case .cancelled: throw CancellationError()
        case .failure: throw e.logs.error(exitCode: e.code)
        }
    }

    // MARK: - SSH

    public enum SSHCheck: Equatable, Sendable {
        case ok
        case rejectedKey
        case hostKeyChanged
        case unreachable(String)
    }

    /// Opens a plain ssh connection to tell apart a wrong key, a changed host key and an unreachable server.
    public func checkSSH(host: String, port: Int, user: String) async -> SSHCheck {
        guard let ssh else { return .ok }
        let lines = LockedLines()
        do {
            let r = try await ProcessRunner.run(
                executable: URL(fileURLWithPath: "/usr/bin/ssh"),
                arguments: ssh.arguments + ["-p", String(port), "\(user)@\(host)", "--", "true"],
                environment: ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin"],
                onStderrLine: { lines.add($0) })
            guard r.exitCode == 255 else { return .ok }
            let text = lines.all
            if text.localizedCaseInsensitiveContains("permission denied") { return .rejectedKey }
            if text.localizedCaseInsensitiveContains("host key verification failed")
                || text.localizedCaseInsensitiveContains("remote host identification has changed") { return .hostKeyChanged }
            return .unreachable(text.split(separator: "\n").last.map(String.init) ?? "Connection failed")
        } catch {
            return .unreachable(error.localizedDescription)
        }
    }

    /// Quotes a value for a POSIX shell.
    public static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Runs a shell command on the server and returns its standard output. Throws when it exits with an error.
    @discardableResult
    public func runRemote(_ remote: SFTPLocation, _ command: String) async throws -> String {
        guard let ssh else { throw ResticError(exitCode: 1, messages: ["No SSH key is set up."]) }
        let lines = LockedLines()
        let r = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/ssh"),
            arguments: ssh.arguments + ["-p", String(remote.port), "\(remote.user)@\(remote.host)", "--", command],
            environment: ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin"],
            onStderrLine: { lines.add($0) })
        if r.exitCode != 0 {
            throw ResticError(exitCode: r.exitCode, rawMessages: lines.all.isEmpty ? ["The command on the server failed."] : [lines.all])
        }
        return String(decoding: r.stdout, as: UTF8.self)
    }

    /// Creates a folder on the server, including its parents.
    public func makeRemoteDirectory(_ remote: SFTPLocation) async throws {
        try await runRemote(remote, "mkdir -p -- \(Self.shellQuote(remote.path))")
    }

    // MARK: - Commands

    public func version() async throws -> String {
        let e = try await executeChecked(["version"], repo: nil)
        return String(decoding: e.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Creates a repository and returns its ID.
    @discardableResult
    public func initRepository(_ repo: ResticRepo) async throws -> String {
        if !repo.isRemote {
            try FileManager.default.createDirectory(at: repo.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        struct Out: Decodable { var id: String }
        let e = try await executeChecked(["init"], repo: repo)
        let line = String(decoding: e.stdout, as: UTF8.self).split(separator: "\n").last.map(String.init) ?? ""
        return (try? JSONDecoder().decode(Out.self, from: Data(line.utf8)).id) ?? ""
    }

    /// True if the path looks like a restic repository.
    public func repositoryExists(at url: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: url.appendingPathComponent("config").path)
            && fm.fileExists(atPath: url.appendingPathComponent("keys").path)
    }

    /// The repository ID. Opening the repository also proves the password is right.
    public func repositoryID(repo: ResticRepo) async throws -> String {
        struct Out: Decodable { var id: String }
        let e = try await executeChecked(["cat", "config"], repo: repo)
        return try JSONDecoder().decode(Out.self, from: e.stdout).id
    }

    /// Disk space the repository uses, after compression and deduplication.
    public func storedSize(repo: ResticRepo) async throws -> Int64 {
        struct Out: Decodable { var total_size: Int64 }
        let e = try await executeChecked(["stats", "--mode", "raw-data"], repo: repo)
        return try JSONDecoder().decode(Out.self, from: e.stdout).total_size
    }

    public func backup(
        repo: ResticRepo,
        options: CreateOptions,
        progress: @escaping @Sendable (CreateProgress) -> Void
    ) async throws -> CreateResult {
        var args = ["backup", "--tag", options.tag, "--read-concurrency", String(options.readConcurrency)]
        if let host = options.host { args += ["--host", host] }
        if options.excludeCaches { args.append("--exclude-caches") }
        if options.oneFileSystem { args.append("--one-file-system") }
        for tag in options.excludeIfPresent { args += ["--exclude-if-present", tag] }
        for p in options.excludePatterns { args += ["--exclude", p] }
        // A negated pattern that comes later wins, so these paths stay in the backup.
        for p in options.includePatterns { args += ["--exclude", "!" + p] }
        args += options.sources

        let summary = SummaryBox()
        let e = try await executeChecked(args, repo: repo, onMessage: { m in
            switch m.message_type {
            case "status":
                let started = (m.total_files ?? 0) > 0
                progress(CreateProgress(
                    fileCount: m.files_done ?? 0,
                    originalSize: m.bytes_done ?? 0,
                    deduplicatedSize: 0,
                    fraction: started ? m.percent_done : nil,
                    currentPath: m.current_files?.first ?? ""))
            case "summary":
                summary.set(m)
            default:
                break
            }
        })
        guard let s = summary.value, let id = s.snapshot_id else { throw e.logs.error(exitCode: e.code) }
        let packed = s.data_added_packed ?? s.data_added ?? 0
        return CreateResult(
            archiveID: id,
            archiveName: String(id.prefix(8)),
            stats: ArchiveStats(
                originalSize: s.total_bytes_processed ?? 0,
                compressedSize: packed,
                deduplicatedSize: packed,
                fileCount: s.total_files_processed ?? 0),
            duration: s.total_duration ?? 0,
            warnings: e.logs.collectedWarnings)
    }

    /// Removes snapshots outside the retention rules and frees their space.
    public func forget(repo: ResticRepo, retention: Retention, tag: String) async throws {
        let keep = retention.arguments
        guard !keep.isEmpty else { return }
        _ = try await executeChecked(
            ["forget", "--tag", tag, "--group-by", "tags"] + keep + ["--prune"], repo: repo)
    }

    public func listArchives(repo: ResticRepo, tag: String? = nil) async throws -> [ArchiveInfo] {
        var args = ["snapshots"]
        if let tag { args += ["--tag", tag] }
        let e = try await executeChecked(args, repo: repo)
        struct S: Decodable { var id: String; var short_id: String?; var time: String }
        let out = try JSONDecoder().decode([S]?.self, from: e.stdout) ?? []
        return out.compactMap { s in
            ResticDate.parse(s.time).map { ArchiveInfo(id: s.id, name: s.short_id ?? String(s.id.prefix(8)), date: $0) }
        }.sorted { $0.date > $1.date }
    }

    /// Streams every item in a snapshot.
    public func listItems(
        repo: ResticRepo,
        snapshot: String,
        handler: @escaping @Sendable (ArchiveItem) -> Void
    ) async throws {
        struct Line: Decodable {
            var struct_type: String?
            var type: String?
            var path: String?
            var size: Int64?
            var mtime: String?
        }
        let decoder = JSONDecoder()
        _ = try await executeChecked(["ls", snapshot], repo: repo, onStdoutLine: { text in
            guard let l = try? decoder.decode(Line.self, from: Data(text.utf8)),
                  l.struct_type == "node", let path = l.path else { return }
            let type: ArchiveItemType = switch l.type {
            case "file": .file
            case "dir": .directory
            case "symlink": .symlink
            default: .other
            }
            handler(ArchiveItem(
                path: String(path.drop { $0 == "/" }), type: type, size: l.size ?? 0,
                modified: l.mtime.flatMap(ResticDate.parse)))
        })
    }

    /// Restores `paths` (snapshot paths without a leading slash) below `destination`, keeping their full paths.
    public func restore(
        repo: ResticRepo,
        snapshot: String,
        paths: [String],
        destination: URL
    ) async throws -> [String] {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        var args = ["restore", snapshot, "--target", destination.path]
        for p in paths { args += ["--include", "/" + p] }
        let e = try await executeChecked(args, repo: repo)
        return e.logs.collectedWarnings
    }

    /// Checks repository consistency and reads a share of the stored data, for example `"1%"`.
    public func check(repo: ResticRepo, readDataSubset: String? = nil) async throws -> CheckResult {
        var args = ["check"]
        if let readDataSubset { args.append("--read-data-subset=" + readDataSubset) }
        let e = try await execute(args, repo: repo)
        switch e.exit {
        case .success: return CheckResult(passed: true, messages: [])
        case .warning: return CheckResult(passed: true, messages: e.logs.collectedWarnings)
        case .cancelled: throw CancellationError()
        case .failure:
            let err = e.logs.error(exitCode: e.code)
            if err.isLockProblem || err.isWrongPassphrase || err.isConnectionProblem { throw err }
            return CheckResult(passed: false, messages: err.messages)
        }
    }

    /// Removes stale locks left by a process that was killed.
    public func unlock(repo: ResticRepo) async throws {
        _ = try await executeChecked(["unlock"], repo: repo)
    }
}

final class SummaryBox: @unchecked Sendable {
    private let lock = NSLock()
    private var m: ResticMessage?
    func set(_ v: ResticMessage) { lock.lock(); m = v; lock.unlock() }
    var value: ResticMessage? { lock.lock(); defer { lock.unlock() }; return m }
}
