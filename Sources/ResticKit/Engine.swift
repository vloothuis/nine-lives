import Foundation

public enum EngineBinary {
    /// Finds nl-engine. Order: `NINELIVES_ENGINE`, the bundled copy, the copy next to restic.
    public static func locate(bundleResources: URL? = Bundle.main.resourceURL, restic: URL? = nil) -> URL? {
        var candidates: [String] = []
        if let env = ProcessInfo.processInfo.environment["NINELIVES_ENGINE"] { candidates.append(env) }
        if let res = bundleResources { candidates.append(res.appendingPathComponent("nl-engine").path) }
        if let restic { candidates.append(restic.deletingLastPathComponent().appendingPathComponent("nl-engine").path) }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }
}

/// A folder that changed since the previous backup. A recursive entry means everything below it may
/// have changed too.
public struct ChangedFolder: Equatable, Hashable, Sendable {
    public var path: String
    public var recursive: Bool

    public init(path: String, recursive: Bool = false) {
        self.path = path
        self.recursive = recursive
    }
}

public enum EngineRun: Equatable, Sendable {
    /// Walks all sources. With `force`, the content of every file is read again.
    case sweep(parent: String?, force: Bool)
    /// Rebuilds only the changed folders of the parent snapshot.
    case splice(parent: String, changes: [ChangedFolder])

    public var isSplice: Bool { if case .splice = self { true } else { false } }
}

/// An item the engine could not read.
public struct EngineItemError: Codable, Equatable, Sendable {
    public var path: String
    public var message: String

    public init(path: String, message: String) {
        self.path = path
        self.message = message
    }

    /// The message in restic's form, `read /path: permission denied`, which `BackupNotes` understands.
    public var resticStyle: String {
        let m = message.prefix(1).lowercased() + message.dropFirst()
        return "read \(path): \(m)"
    }
}

public struct EngineResult: Sendable {
    public var create: CreateResult
    public var run: EngineRun
    public var parent: String?
    public var filesNew: Int64
    public var filesChanged: Int64
    /// A splice changed a file with more than one hard link; its other links may be stale.
    public var hardLinksChanged: Bool
    public var errors: [EngineItemError]
    /// Technical notes for the log, for example that the parent snapshot could not be used.
    public var engineWarnings: [String]
}

/// Runs nl-engine, which makes restic-format snapshots with rustic, either by walking all sources or
/// by rebuilding only folders that changed.
public final class Engine: Sendable {
    public let binary: URL
    public let cacheDirectory: URL?
    public let ssh: SSHOptions?

    public init(binary: URL, cacheDirectory: URL? = nil, ssh: SSHOptions? = nil) {
        self.binary = binary
        self.cacheDirectory = cacheDirectory
        self.ssh = ssh
    }

    /// The engine's arguments for a run, without the changes file.
    func arguments(repo: ResticRepo, options: CreateOptions, run: EngineRun, changesFile: URL?) -> [String] {
        var a: [String]
        switch run {
        case .sweep(let parent, let force):
            a = ["backup"]
            if let parent { a += ["--parent", parent] }
            if force { a.append("--force") }
        case .splice(let parent, _):
            a = ["splice", "--parent", parent]
            if let changesFile { a += ["--changed", changesFile.path] }
        }
        if let remote = repo.remote {
            a += ["--repo", remote.path]
            if let ssh { a += ["--ssh-json", Self.json(ssh.sftpArguments(remote))] }
        } else {
            a += ["--repo", repo.url.path]
        }
        if let cacheDirectory { a += ["--cache-dir", cacheDirectory.path] }
        a += ["--tag", options.tag]
        if let host = options.host { a += ["--host", host] }
        if options.excludeCaches { a.append("--exclude-caches") }
        if options.oneFileSystem { a.append("--one-file-system") }
        for m in options.excludeIfPresent { a += ["--exclude-if-present", m] }
        for n in options.excludeGitignored { a += ["--exclude-gitignored", n] }
        for p in options.excludePatterns { a += ["--exclude", p] }
        for p in options.includePatterns { a += ["--exclude", "!" + p] }
        return a + ["--"] + options.sources
    }

    static func json(_ strings: [String]) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: strings, options: [.withoutEscapingSlashes])) ?? Data("[]".utf8), as: UTF8.self)
    }

    /// The changes file: one absolute path per line, `R ` in front of recursive entries.
    static func changesText(_ changes: [ChangedFolder]) -> String {
        changes.map { ($0.recursive ? "R " : "") + $0.path + "\n" }.joined()
    }

    public func backup(
        repo: ResticRepo,
        options: CreateOptions,
        run: EngineRun,
        progress: @escaping @Sendable (CreateProgress) -> Void
    ) async throws -> EngineResult {
        var changesFile: URL?
        if case .splice(_, let changes) = run {
            let dir = FileManager.default.temporaryDirectory
            let url = dir.appendingPathComponent("nl-engine-changes-\(UUID().uuidString).txt")
            let text = Self.changesText(changes)
            guard FileManager.default.createFile(atPath: url.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600]) else {
                throw ResticError(exitCode: 1, messages: ["Could not write the list of changed folders."])
            }
            changesFile = url
        }
        defer { if let changesFile { try? FileManager.default.removeItem(at: changesFile) } }

        if let cacheDirectory {
            try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        }
        let parser = EngineOutput(folders: run.isSplice ? nil : FolderCollector(), progress: progress)
        let stderr = LockedLines()
        var env: [String: String] = [
            "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": NSHomeDirectory(), "NL_ENGINE_PASSWORD": repo.password,
        ]
        if let v = ProcessInfo.processInfo.environment["NL_ENGINE_SFTP_TIMEOUT"] { env["NL_ENGINE_SFTP_TIMEOUT"] = v }
        let result = try await ProcessRunner.run(
            executable: binary,
            arguments: arguments(repo: repo, options: options, run: run, changesFile: changesFile),
            environment: env,
            // The engine removes its repository lock when signalled, which needs ssh to keep running.
            signalTree: false,
            onStdoutLine: { parser.line($0) },
            onStderrLine: { stderr.add($0) })

        switch result.exitCode {
        case 0, 3: break
        case 130 where Task.isCancelled: throw CancellationError()
        default:
            let lines = stderr.all.split(separator: "\n").map { $0.replacingOccurrences(of: "nl-engine: ", with: "") }
            throw ResticError(exitCode: result.exitCode, messages: lines.isEmpty ? ["The backup engine stopped (code \(result.exitCode))."] : lines)
        }
        guard let s = parser.summary else {
            throw ResticError(exitCode: 1, messages: ["The backup engine finished without a result."] + parser.warnings)
        }
        let packed = s.data_added_packed ?? s.data_added ?? 0
        let errors = parser.errors
        let create = CreateResult(
            archiveID: s.snapshot_id,
            archiveName: String(s.snapshot_id.prefix(8)),
            stats: ArchiveStats(originalSize: s.bytes ?? 0, compressedSize: packed, deduplicatedSize: packed, fileCount: s.files ?? 0),
            duration: s.duration ?? 0,
            warnings: Array(errors.map(\.resticStyle).prefix(200)),
            sample: (s.sample ?? []).compactMap { f in
                f.path.hasPrefix("/") ? SampledFile(path: String(f.path.dropFirst()), size: f.size) : nil
            },
            folders: parser.folders.flatMap { $0.overflowed ? nil : $0 })
        return EngineResult(
            create: create, run: run, parent: s.parent, filesNew: s.files_new ?? 0, filesChanged: s.files_changed ?? 0,
            hardLinksChanged: s.hard_links_changed ?? false, errors: errors, engineWarnings: parser.warnings)
    }
}

/// Parses the engine's JSON lines.
final class EngineOutput: @unchecked Sendable {
    struct Line: Decodable {
        var type: String
        var path: String?
        var items: Int32?
        var files: Int64?
        var bytes: Int64?
        var message: String?
    }

    struct Summary: Decodable {
        struct File: Decodable { var path: String; var size: Int64 }
        var snapshot_id: String
        var parent: String?
        var files: Int64?
        var bytes: Int64?
        var files_new: Int64?
        var files_changed: Int64?
        var data_added: Int64?
        var data_added_packed: Int64?
        var duration: Double?
        var hard_links_changed: Bool?
        var sample: [File]?
    }

    private let lock = NSLock()
    let folders: FolderCollector?
    private let progress: @Sendable (CreateProgress) -> Void
    private var _summary: Summary?
    private var _errors: [EngineItemError] = []
    private var errorCount = 0
    private var _warnings: [String] = []
    private let decoder = JSONDecoder()

    init(folders: FolderCollector?, progress: @escaping @Sendable (CreateProgress) -> Void) {
        self.folders = folders
        self.progress = progress
    }

    var summary: Summary? { lock.withLock { _summary } }
    var errors: [EngineItemError] { lock.withLock { _errors } }
    var warnings: [String] { lock.withLock { _warnings } }

    func line(_ text: String) {
        let data = Data(text.utf8)
        // Folder lines are the most frequent, so they are decoded with the small struct.
        guard let l = try? decoder.decode(Line.self, from: data) else { return }
        switch l.type {
        case "folder":
            if let folders, let p = l.path, let n = l.items { folders.addFolder(p, items: n) }
        case "progress":
            progress(CreateProgress(fileCount: l.files ?? 0, originalSize: l.bytes ?? 0, deduplicatedSize: 0, fraction: nil,
                                    currentPath: l.path ?? ""))
        case "error":
            guard let p = l.path else { return }
            folders?.addUnreadable(p)
            lock.withLock {
                errorCount += 1
                // Keeps memory bounded when a whole tree is unreadable.
                if _errors.count < 10_000 { _errors.append(EngineItemError(path: p, message: l.message ?? "unreadable")) }
            }
        case "warning":
            if let m = l.message { lock.withLock { if _warnings.count < 50 { _warnings.append(m) } } }
        case "summary":
            if let s = try? decoder.decode(Summary.self, from: data) { lock.withLock { _summary = s } }
        default:
            break
        }
    }
}
