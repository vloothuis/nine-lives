import Foundation

/// Collects the folder tree of a backup from restic's per-file lines, with item counts per folder.
///
/// Only folders are kept. Names are stored once, so a home folder with 800,000 folders needs a few
/// tens of MB while the backup runs. When `limit` folders are reached, collecting stops.
public final class FolderCollector: @unchecked Sendable {
    private let lock = NSLock()
    public let limit: Int

    public private(set) var names: [String] = [""]
    private var nameIDs: [String: Int32] = ["": 0]
    /// Per folder, indexed by node number. Node 0 is `/`.
    public private(set) var parent: [Int32] = [-1]
    public private(set) var name: [Int32] = [0]
    /// Items directly in the folder: files, links and sub-folders that were backed up.
    public private(set) var items: [Int32] = [0]
    /// True when restic could not read the folder or an item in it, so its contents are unknown.
    public private(set) var unknown: [Bool] = [false]
    private var children: [Int64: Int32] = [:]
    /// The bytes, component ends and nodes of the last folder path that was looked up.
    private var lastDir: [UInt8] = []
    private var lastEnds: [Int] = []
    private var lastNodes: [Int32] = []
    public private(set) var overflowed = false

    public init(limit: Int = 2_000_000) {
        self.limit = limit
    }

    public var count: Int { lock.withLock { parent.count } }

    /// Reads one `verbose_status` line. Folder items end in `/`.
    /// Works on the raw bytes, because a backup can have millions of lines.
    public func addVerboseLine(_ line: String) {
        var line = line
        let escaped: String? = line.withUTF8 { buf -> String? in
            guard let base = buf.baseAddress else { return nil }
            let needle: StaticString = "\"item\":\""
            guard let hit = memmem(base, buf.count, needle.utf8Start, needle.utf8CodeUnitCount) else { return nil }
            let start = UnsafePointer(hit.assumingMemoryBound(to: UInt8.self)) - base + needle.utf8CodeUnitCount
            var end = start
            while end < buf.count, buf[end] != 0x22, buf[end] != 0x5C { end += 1 }
            guard end < buf.count else { return nil }
            if buf[end] == 0x5C { return Self.item(in: String(decoding: buf, as: UTF8.self)) }
            add(UnsafeBufferPointer(rebasing: buf[start..<end]))
            return nil
        }
        if let escaped {
            var e = escaped
            e.withUTF8 { add($0) }
        }
    }

    private func add(_ item: UnsafeBufferPointer<UInt8>) {
        lock.lock(); defer { lock.unlock() }
        guard !overflowed, item.first == 0x2F else { return }
        if item.last == 0x2F {
            guard item.count > 1, let n = node(for: UnsafeBufferPointer(rebasing: item[0..<item.count - 1])) else { return }
            // A folder line comes after its contents, so it is counted as an item of its parent.
            let p = parent[Int(n)]
            if p >= 0 { items[Int(p)] += 1 }
        } else {
            var slash = item.count - 1
            while slash > 0, item[slash] != 0x2F { slash -= 1 }
            guard let n = slash == 0 ? 0 : node(for: UnsafeBufferPointer(rebasing: item[0..<slash])) else { return }
            items[Int(n)] += 1
        }
    }

    /// Marks a path restic reported as unreadable.
    public func addUnreadable(_ path: String) {
        var p = path
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        lock.lock(); defer { lock.unlock() }
        guard !overflowed, p.hasPrefix("/"), p.count > 1 else { return }
        let n = p.withUTF8 { node(for: $0) }
        if let n { unknown[Int(n)] = true }
    }

    /// The node for a folder path such as `/a/b`. Reuses the walk of the previous path,
    /// because restic reports items folder by folder.
    private func node(for dir: UnsafeBufferPointer<UInt8>) -> Int32? {
        // Longest shared start with the last path that ends at a component boundary.
        var shared = 0
        var level = 0
        while level < lastEnds.count {
            let e = lastEnds[level]
            guard e <= dir.count, e == dir.count || dir[e] == 0x2F else { break }
            var same = true
            var k = shared
            while k < e { if dir[k] != lastDir[k] { same = false; break }; k += 1 }
            guard same else { break }
            shared = e
            level += 1
        }
        lastDir.removeSubrange(shared...)
        lastEnds.removeSubrange(level...)
        lastNodes.removeSubrange(level...)
        var cur: Int32 = level == 0 ? 0 : lastNodes[level - 1]
        var i = shared
        while i < dir.count {
            while i < dir.count, dir[i] == 0x2F { i += 1 }
            guard i < dir.count else { break }
            var j = i
            while j < dir.count, dir[j] != 0x2F { j += 1 }
            let id = intern(UnsafeBufferPointer(rebasing: dir[i..<j]))
            let key = Int64(cur) << 32 | Int64(id)
            if let c = children[key] {
                cur = c
            } else {
                guard parent.count < limit else { overflowed = true; return nil }
                let n = Int32(parent.count)
                parent.append(cur); name.append(id); items.append(0); unknown.append(false)
                children[key] = n
                cur = n
            }
            lastDir.append(contentsOf: UnsafeBufferPointer(rebasing: dir[shared..<j]))
            shared = j
            lastEnds.append(j)
            lastNodes.append(cur)
            i = j
        }
        return cur
    }

    private func intern(_ bytes: UnsafeBufferPointer<UInt8>) -> Int32 {
        let str = String(decoding: bytes, as: UTF8.self)
        if let id = nameIDs[str] { return id }
        let id = Int32(names.count)
        names.append(str)
        nameIDs[str] = id
        return id
    }

    /// The `item` field of a restic JSON line. Reads the string directly when it has no escapes,
    /// and decodes the line as JSON when it has.
    public static func item(in line: String) -> String? {
        guard let r = line.range(of: "\"item\":\"") else { return nil }
        let rest = line[r.upperBound...]
        guard let end = rest.firstIndex(where: { $0 == "\"" || $0 == "\\" }) else { return nil }
        if rest[end] == "\"" { return String(rest[..<end]) }
        struct L: Decodable { var item: String? }
        return (try? JSONDecoder().decode(L.self, from: Data(line.utf8)))?.item
    }
}
