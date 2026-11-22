import Foundation

public enum BorgBinary {
    /// Finds a usable borg executable. Order: explicit override, bundled copy, Homebrew, PATH-like locations.
    public static func locate(override: String? = nil, bundleResources: URL? = Bundle.main.resourceURL) -> URL? {
        var candidates: [String] = []
        if let override, !override.isEmpty { candidates.append(override) }
        if let env = ProcessInfo.processInfo.environment["NINELIVES_BORG"] { candidates.append(env) }
        if let res = bundleResources {
            candidates.append(res.appendingPathComponent("borg/borg").path)
            candidates.append(res.appendingPathComponent("borg").path)
        }
        candidates += ["/opt/homebrew/bin/borg", "/usr/local/bin/borg"]
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

public enum BorgDate {
    /// Borg prints local time without a time zone, with microseconds.
    public static func parse(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        for format in ["yyyy-MM-dd'T'HH:mm:ss.SSSSSS", "yyyy-MM-dd'T'HH:mm:ss"] {
            f.dateFormat = format
            if let d = f.date(from: s) { return d }
        }
        return nil
    }
}

/// Thin, typed wrapper around the borg command line.
///
/// All calls are independent processes. Callers must make sure that only one
/// operation uses a repository at a time, because borg takes an exclusive lock.
public final class Borg: Sendable {
    public let binary: URL
    /// Isolates borg's cache, config and security directories from any borg the user runs themselves.
    public let baseDirectory: URL?
    public let ssh: SSHOptions?

    public init(binary: URL, baseDirectory: URL? = nil, ssh: SSHOptions? = nil) {
        self.binary = binary
        self.baseDirectory = baseDirectory
        self.ssh = ssh
    }

    // MARK: - Plumbing

    func environment(passphrase: String?) -> [String: String] {
        var env: [String: String] = [
            "BORG_EXIT_CODES": "modern",
            "BORG_RELOCATED_REPO_ACCESS_IS_OK": "yes",
            "BORG_UNKNOWN_UNENCRYPTED_REPO_ACCESS_IS_OK": "yes",
            "BORG_HOSTNAME_IS_UNIQUE": "yes",
            "BORG_CHECK_I_KNOW_WHAT_I_AM_DOING": "NO",
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": NSHomeDirectory(),
        ]
        if let passphrase { env["BORG_PASSPHRASE"] = passphrase }
        if let baseDirectory { env["BORG_BASE_DIR"] = baseDirectory.path }
        if let ssh { env["BORG_RSH"] = ssh.command }
        return env
    }

    struct Execution {
        var stdout: Data
        var exit: BorgExit
        var code: Int32
        var logs: LogCollector
    }

    func execute(
        _ args: [String],
        passphrase: String?,
        workingDirectory: URL? = nil,
        stdoutLine: (@Sendable (String) -> Void)? = nil,
        onLog: (@Sendable (BorgLogLine) -> Void)? = nil
    ) async throws -> Execution {
        if let baseDirectory {
            try? FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        }
        let logs = LogCollector()
        let result = try await ProcessRunner.run(
            executable: binary,
            arguments: args,
            environment: environment(passphrase: passphrase),
            currentDirectory: workingDirectory,
            onStdoutLine: stdoutLine,
            onStderrLine: { line in
                if let parsed = BorgLogLine.parse(line) {
                    logs.add(parsed)
                    onLog?(parsed)
                } else {
                    logs.addRaw(line)
                }
            }
        )
        return Execution(stdout: result.stdout, exit: BorgExit(code: result.exitCode), code: result.exitCode, logs: logs)
    }

    /// Like `execute`, but throws on failure and cancellation.
    func executeChecked(
        _ args: [String],
        passphrase: String?,
        workingDirectory: URL? = nil,
        stdoutLine: (@Sendable (String) -> Void)? = nil,
        onLog: (@Sendable (BorgLogLine) -> Void)? = nil
    ) async throws -> Execution {
        let e = try await execute(args, passphrase: passphrase, workingDirectory: workingDirectory, stdoutLine: stdoutLine, onLog: onLog)
        switch e.exit {
        case .success, .warning: return e
        case .cancelled: throw CancellationError()
        case .failure: throw e.logs.error(exitCode: e.code)
        }
    }

    private func spec(_ repo: BorgRepo, archive: String? = nil) -> String {
        let base = repo.remote ?? repo.url.path
        return archive.map { "\(base)::\($0)" } ?? base
    }

    /// Options that go right after the borg subcommand.
    private func common(_ repo: BorgRepo) -> [String] {
        var a = ["--log-json"]
        if let p = repo.remotePath, !p.isEmpty { a += ["--remote-path", p] }
        return a
    }

    // MARK: - SSH preflight

    public enum SSHCheck: Equatable, Sendable {
        case ok
        case rejectedKey
        case hostKeyChanged
        case unreachable(String)
    }

    /// Opens a plain ssh connection to tell apart a wrong key, a changed host key and an unreachable server.
    /// borg alone reports all of these as "connection closed".
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

    /// Creates a folder on the server. Older borg servers (1.2 and earlier) cannot create parent folders themselves.
    public func makeRemoteDirectory(host: String, port: Int, user: String, path: String) async throws {
        guard let ssh else { return }
        let lines = LockedLines()
        let quoted = "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let r = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/ssh"),
            arguments: ssh.arguments + ["-p", String(port), "\(user)@\(host)", "--", "mkdir -p -- \(quoted)"],
            environment: ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin"],
            onStderrLine: { lines.add($0) })
        if r.exitCode != 0 { throw BorgError(exitCode: r.exitCode, rawMessages: lines.all.isEmpty ? ["Could not create the folder on the server."] : [lines.all]) }
    }

    // MARK: - Commands

    public func version() async throws -> String {
        let e = try await executeChecked(["--version"], passphrase: nil)
        return String(decoding: e.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func initRepository(_ repo: BorgRepo, mode: EncryptionMode) async throws {
        if !repo.isRemote {
            try FileManager.default.createDirectory(
                at: repo.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        _ = try await executeChecked(
            ["init"] + common(repo) + ["-e", mode.rawValue] + [spec(repo)],
            passphrase: repo.passphrase)
    }

    /// True if the path looks like a borg repository (has a `config` and `data` entry).
    public func repositoryExists(at url: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: url.appendingPathComponent("config").path)
            && fm.fileExists(atPath: url.appendingPathComponent("data").path)
    }

    public func create(
        repo: BorgRepo,
        archive: String,
        options: CreateOptions,
        progress: @escaping @Sendable (CreateProgress) -> Void
    ) async throws -> CreateResult {
        var args = ["create"] + common(repo) + ["--progress", "--json", "--stats",
                    "-C", options.compression, "--checkpoint-interval", "300"]
        if options.excludeCaches { args += ["--exclude-caches", "--keep-exclude-tags"] }
        if options.oneFileSystem { args += ["--one-file-system"] }
        for tag in options.excludeIfPresent { args += ["--exclude-if-present", tag, "--keep-exclude-tags"] }
        for p in options.excludePatterns { args += ["--exclude", p] }
        args.append(spec(repo, archive: archive))
        args += options.sources

        let throttle = Throttle(interval: 0.25)
        let e = try await executeChecked(args, passphrase: repo.passphrase, onLog: { line in
            guard line.type == "archive_progress", line.finished != true else { return }
            guard throttle.allow() else { return }
            progress(CreateProgress(
                fileCount: line.nfiles ?? 0,
                originalSize: line.original_size ?? 0,
                compressedSize: line.compressed_size ?? 0,
                deduplicatedSize: line.deduplicated_size ?? 0,
                currentPath: line.path.map { "/" + $0 } ?? ""
            ))
        })

        struct Out: Decodable {
            struct Arch: Decodable {
                struct Stats: Decodable {
                    var original_size: Int64
                    var compressed_size: Int64
                    var deduplicated_size: Int64
                    var nfiles: Int64
                }
                var id: String
                var name: String
                var duration: Double
                var stats: Stats
            }
            var archive: Arch
        }
        let out = try JSONDecoder().decode(Out.self, from: e.stdout)
        return CreateResult(
            archiveID: out.archive.id,
            archiveName: out.archive.name,
            stats: ArchiveStats(
                originalSize: out.archive.stats.original_size,
                compressedSize: out.archive.stats.compressed_size,
                deduplicatedSize: out.archive.stats.deduplicated_size,
                fileCount: out.archive.stats.nfiles),
            duration: out.archive.duration,
            warnings: e.logs.collectedWarnings.filter { !$0.hasPrefix("\nIMPORTANT") })
    }

    public func prune(repo: BorgRepo, retention: Retention, glob: String) async throws {
        let keep = retention.arguments
        guard !keep.isEmpty else { return }
        _ = try await executeChecked(
            ["prune"] + common(repo) + ["-a", glob] + keep + [spec(repo)], passphrase: repo.passphrase)
    }

    public func compact(repo: BorgRepo) async throws {
        _ = try await executeChecked(["compact"] + common(repo) + [spec(repo)], passphrase: repo.passphrase)
    }

    public func listArchives(repo: BorgRepo, glob: String? = nil) async throws -> [ArchiveInfo] {
        var args = ["list"] + common(repo) + ["--json"]
        if let glob { args += ["-a", glob] }
        args.append(spec(repo))
        let e = try await executeChecked(args, passphrase: repo.passphrase)
        struct Out: Decodable {
            struct A: Decodable { var id: String; var name: String; var time: String }
            var archives: [A]
        }
        let out = try JSONDecoder().decode(Out.self, from: e.stdout)
        return out.archives.compactMap { a in
            BorgDate.parse(a.time).map { ArchiveInfo(id: a.id, name: a.name, date: $0) }
        }.sorted { $0.date > $1.date }
    }

    public func info(repo: BorgRepo) async throws -> RepositoryInfo {
        let e = try await executeChecked(["info"] + common(repo) + ["--json", spec(repo)], passphrase: repo.passphrase)
        struct Out: Decodable {
            struct Cache: Decodable {
                struct Stats: Decodable { var unique_csize: Int64; var total_size: Int64 }
                var stats: Stats
            }
            struct Repo: Decodable { var id: String }
            struct Enc: Decodable { var mode: String }
            var cache: Cache
            var repository: Repo
            var encryption: Enc
        }
        let out = try JSONDecoder().decode(Out.self, from: e.stdout)
        return RepositoryInfo(
            id: out.repository.id, encryption: out.encryption.mode, storedSize: out.cache.stats.unique_csize,
            totalOriginalSize: out.cache.stats.total_size)
    }

    /// Streams every item in an archive.
    public func listItems(
        repo: BorgRepo,
        archive: String,
        handler: @escaping @Sendable (ArchiveItem) -> Void
    ) async throws {
        struct Line: Decodable {
            var type: String
            var path: String
            var size: Int64?
            var mtime: String?
            var healthy: Bool?
        }
        let decoder = JSONDecoder()
        _ = try await executeChecked(
            ["list"] + common(repo) + ["--json-lines", spec(repo, archive: archive)],
            passphrase: repo.passphrase,
            stdoutLine: { text in
                guard let data = text.data(using: .utf8), let l = try? decoder.decode(Line.self, from: data) else { return }
                handler(ArchiveItem(
                    path: l.path,
                    type: ArchiveItemType(rawValue: l.type) ?? .other,
                    size: l.size ?? 0,
                    modified: l.mtime.flatMap(BorgDate.parse),
                    isHealthy: l.healthy ?? true))
            })
    }

    /// Extracts `paths` (archive paths without a leading slash) below `destination`.
    /// With `stripComponents` set, that many leading path components are removed.
    public func extract(
        repo: BorgRepo,
        archive: String,
        paths: [String],
        destination: URL,
        stripComponents: Int = 0
    ) async throws -> [String] {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        var args = ["extract"] + common(repo)
        if stripComponents > 0 { args += ["--strip-components", String(stripComponents)] }
        args.append(spec(repo, archive: archive))
        args += paths.map { "pp:" + $0 }
        let e = try await executeChecked(args, passphrase: repo.passphrase, workingDirectory: destination)
        return e.logs.collectedWarnings
    }

    /// Checks repository consistency. With `maxDuration`, only part of the data is read.
    public func check(repo: BorgRepo, maxDuration: TimeInterval? = nil) async throws -> CheckResult {
        var args = ["check"] + common(repo) + ["--repository-only"]
        if let maxDuration { args += ["--max-duration", String(Int(maxDuration))] }
        args.append(spec(repo))
        let e = try await execute(args, passphrase: repo.passphrase)
        switch e.exit {
        case .success: return CheckResult(passed: true, messages: [])
        case .warning: return CheckResult(passed: true, messages: e.logs.collectedWarnings)
        case .cancelled: throw CancellationError()
        case .failure:
            let err = e.logs.error(exitCode: e.code)
            if err.isLockProblem || err.isWrongPassphrase { throw err }
            return CheckResult(passed: false, messages: err.messages)
        }
    }

    /// Removes a stale lock. Only call when no other borg process uses this repository.
    public func breakLock(repo: BorgRepo) async throws {
        _ = try await executeChecked(["break-lock"] + common(repo) + [spec(repo)], passphrase: repo.passphrase)
    }
}

final class Throttle: @unchecked Sendable {
    private let interval: TimeInterval
    private var last: TimeInterval = 0
    private let lock = NSLock()
    init(interval: TimeInterval) { self.interval = interval }
    func allow() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        if now - last >= interval { last = now; return true }
        return false
    }
}
