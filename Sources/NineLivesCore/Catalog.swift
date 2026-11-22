import Foundation
import ResticKit

public struct CatalogEntry: Identifiable, Hashable, Sendable {
    public var id: String { path }
    /// Archive path without leading slash, for example `Users/me/Documents/a.txt`.
    public var path: String
    public var name: String
    public var isDirectory: Bool
    public var isSymlink: Bool
    public var size: Int64
    public var modified: Date?

    /// The absolute path this item had on the Mac.
    public var originalPath: String { "/" + path }
}

/// A local SQLite index of one archive, so browsing and searching do not need the disk.
public final class Catalog: @unchecked Sendable {
    private let db: SQLiteDB
    private let lock = NSLock()
    public let url: URL

    init(url: URL, readOnly: Bool) throws {
        self.url = url
        db = try SQLiteDB(path: url.path, readOnly: readOnly)
    }

    public static func open(at url: URL) throws -> Catalog? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let c = try Catalog(url: url, readOnly: true)
        return c.isComplete ? c : nil
    }

    var isComplete: Bool {
        lock.lock(); defer { lock.unlock() }
        guard let s = try? db.prepare("SELECT value FROM meta WHERE key='complete'") else { return false }
        return s.step() && s.text(0) == "1"
    }

    /// Reads the whole snapshot listing from restic into a new catalog file.
    public static func build(
        restic: Restic, repo: ResticRepo, snapshot: String, at url: URL,
        progress: @escaping @Sendable (Int) -> Void
    ) async throws -> Catalog {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = url.appendingPathExtension("partial")
        try? fm.removeItem(at: partial)
        let writer = try CatalogWriter(path: partial.path)
        do {
            try await restic.listItems(repo: repo, snapshot: snapshot) { item in
                writer.add(item)
                progress(writer.count)
            }
            try writer.finish()
        } catch {
            writer.abort()
            try? fm.removeItem(at: partial)
            throw error
        }
        try? fm.removeItem(at: url)
        try fm.moveItem(at: partial, to: url)
        guard let catalog = try open(at: url) else { throw SQLiteError(message: "Catalog is incomplete") }
        return catalog
    }

    private func entries(_ sql: String, bind: (SQLiteDB.Statement) -> Void) -> [CatalogEntry] {
        lock.lock(); defer { lock.unlock() }
        guard let s = try? db.prepare(sql) else { return [] }
        bind(s)
        var out: [CatalogEntry] = []
        while s.step() {
            out.append(CatalogEntry(
                path: s.text(0), name: s.text(1),
                isDirectory: s.text(2) == "d", isSymlink: s.text(2) == "l",
                size: s.int(3), modified: s.double(4).map { Date(timeIntervalSince1970: $0) }))
        }
        return out
    }

    private static let columns = "path, name, type, size, mtime"

    /// Direct children of a directory. Use "" for the top level.
    public func children(of directory: String) -> [CatalogEntry] {
        entries("SELECT \(Self.columns) FROM entries WHERE parent = ?1 ORDER BY type != 'd', name COLLATE NOCASE") {
            $0.bind(1, directory)
        }
    }

    public func search(_ text: String, limit: Int = 300) -> [CatalogEntry] {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        return entries("SELECT \(Self.columns) FROM entries WHERE name LIKE ?1 ESCAPE '\\' ORDER BY mtime DESC LIMIT \(limit)") {
            $0.bind(1, "%\(escaped)%")
        }
    }

    public func entry(at path: String) -> CatalogEntry? {
        entries("SELECT \(Self.columns) FROM entries WHERE path = ?1") { $0.bind(1, path) }.first
    }

    /// Random regular files of modest size, used for restore tests.
    public func randomFiles(count: Int, maxSize: Int64 = 20_000_000) -> [CatalogEntry] {
        entries("SELECT \(Self.columns) FROM entries WHERE type = '-' AND size > 0 AND size <= ?1 ORDER BY RANDOM() LIMIT \(count)") {
            $0.bind(1, maxSize)
        }
    }

    public var fileCount: Int {
        lock.lock(); defer { lock.unlock() }
        guard let s = try? db.prepare("SELECT COUNT(*) FROM entries WHERE type != 'd'"), s.step() else { return 0 }
        return Int(s.int(0))
    }
}

final class CatalogWriter: @unchecked Sendable {
    private let db: SQLiteDB
    private let insert: SQLiteDB.Statement
    private var knownDirectories: Set<String> = [""]
    private(set) var count = 0

    init(path: String) throws {
        db = try SQLiteDB(path: path)
        try db.exec("PRAGMA journal_mode=OFF; PRAGMA synchronous=OFF;")
        try db.exec("""
            CREATE TABLE entries(path TEXT PRIMARY KEY, parent TEXT NOT NULL, name TEXT NOT NULL,
                                 type TEXT NOT NULL, size INTEGER NOT NULL, mtime REAL) WITHOUT ROWID;
            CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT);
            """)
        insert = try db.prepare("INSERT OR REPLACE INTO entries VALUES (?1, ?2, ?3, ?4, ?5, ?6)")
        try db.exec("BEGIN")
    }

    private func row(path: String, type: String, size: Int64, mtime: Double?) {
        let (parent, name) = Self.split(path)
        insert.bind(1, path); insert.bind(2, parent); insert.bind(3, name)
        insert.bind(4, type); insert.bind(5, size); insert.bind(6, mtime)
        insert.step()
        insert.reset()
    }

    static func split(_ path: String) -> (String, String) {
        guard let slash = path.lastIndex(of: "/") else { return ("", path) }
        return (String(path[..<slash]), String(path[path.index(after: slash)...]))
    }

    /// Listings may skip parent folders such as `Users`, so add them.
    private func ensureAncestors(of path: String) {
        var chain: [String] = []
        var current = Self.split(path).0
        while !current.isEmpty && !knownDirectories.contains(current) {
            chain.append(current)
            current = Self.split(current).0
        }
        for dir in chain.reversed() {
            row(path: dir, type: "d", size: 0, mtime: nil)
            knownDirectories.insert(dir)
        }
    }

    func add(_ item: ArchiveItem) {
        var path = item.path
        while path.hasSuffix("/") && path.count > 1 { path.removeLast() }
        guard !path.isEmpty else { return }
        ensureAncestors(of: path)
        let type = item.type == .hardlink ? "-" : item.type.rawValue
        row(path: path, type: type, size: item.size, mtime: item.modified?.timeIntervalSince1970)
        if item.type == .directory { knownDirectories.insert(path) }
        count += 1
        if count % 50_000 == 0 {
            try? db.exec("COMMIT; BEGIN")
        }
    }

    func finish() throws {
        try db.exec("CREATE INDEX idx_parent ON entries(parent)")
        try db.exec("INSERT OR REPLACE INTO meta VALUES('complete','1')")
        try db.exec("COMMIT")
    }

    func abort() { try? db.exec("ROLLBACK") }
}

/// Manages catalog files on this Mac.
public final class CatalogStore: @unchecked Sendable {
    private let directory: URL
    public init(directory: URL) { self.directory = directory }

    public func url(forArchiveID id: String) -> URL {
        directory.appendingPathComponent("\(id.prefix(32)).sqlite")
    }

    public func cached(archiveID: String) -> Catalog? {
        try? Catalog.open(at: url(forArchiveID: archiveID))
    }

    public func catalog(
        for archive: ArchiveInfo, restic: Restic, repo: ResticRepo,
        progress: @escaping @Sendable (Int) -> Void
    ) async throws -> Catalog {
        if let c = cached(archiveID: archive.id) { return c }
        let c = try await Catalog.build(restic: restic, repo: repo, snapshot: archive.id, at: url(forArchiveID: archive.id), progress: progress)
        trim(keep: 6)
        return c
    }

    /// Keeps the newest catalogs and removes the rest.
    public func trim(keep: Int) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let sqlite = files.filter { $0.pathExtension == "sqlite" }.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a > b
        }
        for f in sqlite.dropFirst(keep) { try? fm.removeItem(at: f) }
    }
}
