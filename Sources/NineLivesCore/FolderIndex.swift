import Foundation
import Compression
import ResticKit

/// The folders of one backup, in depth-first order, with the number of items below each folder.
/// Used to see how much a skip pattern would match besides the folders it is meant for.
public struct FolderIndex: Sendable {
    static let magic: UInt32 = 0x4E4C_4649 // "NLFI"
    static let version: UInt32 = 2

    /// The snapshot this index describes.
    public let snapshotID: String
    let names: [String]
    let nameIDs: [String: UInt32]
    let name: [UInt32]
    /// One past the last node of the subtree. The subtree of node i is i..<end[i].
    let end: [UInt32]
    /// Items in the subtree, the folder itself not counted.
    let items: [UInt32]
    /// Bit 0: the folder could not be fully read. Bit 1: some folder in the subtree could not.
    let flags: [UInt8]

    public var count: Int { name.count }

    // MARK: Building

    public init(_ c: FolderCollector, snapshotID: String) {
        self.snapshotID = snapshotID
        let parent = c.parent, cname = c.name, citems = c.items, cunknown = c.unknown, names = c.names
        let n = parent.count
        var childCount = [Int](repeating: 0, count: n + 1)
        for i in 1..<max(n, 1) { childCount[Int(parent[i]) + 1] += 1 }
        var start = childCount
        for i in 1...n { start[i] += start[i - 1] }
        var kids = [Int32](repeating: 0, count: max(n - 1, 0))
        var fill = start
        for i in 1..<max(n, 1) {
            let p = Int(parent[i])
            kids[fill[p]] = Int32(i)
            fill[p] += 1
        }
        for p in 0..<n where start[p + 1] - start[p] > 1 {
            kids[start[p]..<start[p + 1]].sort { names[Int(cname[Int($0)])] < names[Int(cname[Int($1)])] }
        }

        var order = [Int32](); order.reserveCapacity(n)
        var stack: [Int32] = n > 0 ? [0] : []
        while let x = stack.popLast() {
            order.append(x)
            stack.append(contentsOf: kids[start[Int(x)]..<start[Int(x) + 1]].reversed())
        }
        var pos = [Int](repeating: 0, count: n)
        for (i, x) in order.enumerated() { pos[Int(x)] = i }

        var name = [UInt32](repeating: 0, count: n)
        var end = [UInt32](repeating: 0, count: n)
        var items = [UInt32](repeating: 0, count: n)
        var flags = [UInt8](repeating: 0, count: n)
        for (i, x) in order.enumerated() {
            name[i] = UInt32(cname[Int(x)])
            items[i] = UInt32(max(citems[Int(x)], 0))
            if cunknown[Int(x)] { flags[i] = 3 }
        }
        // Children come after their parent, so a backwards pass sums subtrees.
        for i in stride(from: n - 1, through: 0, by: -1) {
            if end[i] == 0 { end[i] = UInt32(i + 1) }
            let x = Int(order[i])
            let p = Int(parent[x])
            guard p >= 0 else { continue }
            let pi = pos[p]
            end[pi] = max(end[pi], end[i], UInt32(pi + 1))
            let (sum, over) = items[pi].addingReportingOverflow(items[i])
            items[pi] = over ? .max : sum
            if flags[i] & 2 != 0 { flags[pi] |= 2 }
        }
        self.names = names
        self.nameIDs = Self.ids(names)
        self.name = name
        self.end = end
        self.items = items
        self.flags = flags
    }

    init(snapshotID: String, names: [String], name: [UInt32], end: [UInt32], items: [UInt32], flags: [UInt8]) {
        self.snapshotID = snapshotID
        self.names = names
        self.nameIDs = Self.ids(names)
        self.name = name
        self.end = end
        self.items = items
        self.flags = flags
    }

    static func ids(_ names: [String]) -> [String: UInt32] {
        var d = [String: UInt32](minimumCapacity: names.count)
        for (i, n) in names.enumerated() where d[n] == nil { d[n] = UInt32(i) }
        return d
    }

    // MARK: Queries

    func child(of i: Int, named id: UInt32) -> Int? {
        var found: Int?
        forEachChild(of: i) { if name[$0] == id { found = $0; return false }; return true }
        return found
    }

    /// Calls body for each child until it returns false.
    func forEachChild(of i: Int, _ body: (Int) -> Bool) {
        var j = i + 1
        let stop = Int(end[i])
        while j < stop {
            guard body(j) else { return }
            let next = Int(end[j])
            guard next > j, next <= stop else { return }
            j = next
        }
    }

    func children(of i: Int) -> [Int] {
        var out: [Int] = []
        var j = i + 1
        let stop = Int(end[i])
        while j < stop {
            out.append(j)
            let next = Int(end[j])
            guard next > j, next <= stop else { break }
            j = next
        }
        return out
    }

    /// The node for an absolute folder path.
    public func node(at path: String) -> Int? {
        guard count > 0 else { return nil }
        var cur = 0
        for comp in path.split(separator: "/") {
            guard let id = nameIDs[String(comp)], let c = child(of: cur, named: id) else { return nil }
            cur = c
        }
        return cur
    }

    /// Folders matched by an absolute restic pattern whose components do not cross `/`.
    public func matches(_ pattern: String) -> [Int] {
        guard count > 0 else { return [] }
        var frontier = [0]
        for comp in pattern.split(separator: "/") {
            let p = String(comp)
            var next: [Int] = []
            if let literal = FolderGlob.literal(p) {
                guard let id = nameIDs[literal] else { return [] }
                for f in frontier { if let c = child(of: f, named: id) { next.append(c) } }
            } else {
                var seen: [UInt32: Bool] = [:]
                for f in frontier {
                    forEachChild(of: f) { c in
                        let id = name[c]
                        let ok = seen[id] ?? { let m = FolderGlob.match(p, names[Int(id)]); seen[id] = m; return m }()
                        if ok { next.append(c) }
                        return true
                    }
                }
            }
            frontier = next
            if frontier.isEmpty { break }
        }
        return frontier
    }

    public struct Extra: Equatable, Sendable {
        /// Folders matched that are not among the intended folders.
        public var folders: Int
        /// Items in and below those folders.
        public var items: Int
        /// True when one of them holds a folder that could not be read, so its size is unknown.
        public var unknown: Bool
    }

    /// What a pattern matches besides the given folders. Nil when one of the folders is not in the index.
    public func extra(of pattern: String, besides folders: [String]) -> Extra? {
        var intended = Set<Int>()
        for f in folders {
            guard let n = node(at: f) else { return nil }
            intended.insert(n)
        }
        var e = Extra(folders: 0, items: 0, unknown: false)
        for m in matches(pattern) where !intended.contains(m) {
            e.folders += 1
            e.items += Int(items[m]) + 1
            if flags[m] & 2 != 0 { e.unknown = true }
        }
        return e
    }

    // MARK: File format

    public func data() -> Data {
        let blob = Array(names.joined(separator: "\0").utf8)
        let id = Array(snapshotID.utf8)
        var d = [UInt8]()
        d.reserveCapacity(32 + id.count + blob.count + count * 13)
        func put(_ v: UInt32) {
            d.append(UInt8(v & 0xFF)); d.append(UInt8(v >> 8 & 0xFF)); d.append(UInt8(v >> 16 & 0xFF)); d.append(UInt8(v >> 24))
        }
        put(Self.magic); put(Self.version)
        put(UInt32(id.count)); d += id
        put(UInt32(names.count)); put(UInt32(blob.count)); d += blob
        put(UInt32(count))
        // Whole columns, copied as they are. Every Mac Nine Lives runs on is little-endian.
        name.withUnsafeBytes { d.append(contentsOf: $0) }
        end.withUnsafeBytes { d.append(contentsOf: $0) }
        items.withUnsafeBytes { d.append(contentsOf: $0) }
        d += flags
        var out = [UInt8](repeating: 0, count: d.count + 4096)
        let n = d.withUnsafeBufferPointer { src in
            compression_encode_buffer(&out, out.count, src.baseAddress!, src.count, nil, COMPRESSION_LZFSE)
        }
        return Data(out.prefix(n))
    }

    /// Reads an index and checks every count and offset. Returns nil for anything unexpected.
    public init?(data compressed: Data) {
        guard let d = try? (compressed as NSData).decompressed(using: .lzfse) as Data else { return nil }
        let bytes = [UInt8](d)
        var at = 0
        func u32() -> UInt32? {
            guard at + 4 <= bytes.count else { return nil }
            defer { at += 4 }
            return UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
        }
        func take(_ n: Int) -> ArraySlice<UInt8>? {
            guard n >= 0, at + n <= bytes.count else { return nil }
            defer { at += n }
            return bytes[at..<at + n]
        }
        guard u32() == Self.magic, u32() == Self.version,
              let idLen = u32(), let idBytes = take(Int(idLen)), let id = String(bytes: idBytes, encoding: .utf8),
              let nameCount = u32(), let blobLen = u32(), let blob = take(Int(blobLen)),
              let s = String(bytes: blob, encoding: .utf8), let n = u32() else { return nil }
        let names = s.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        guard names.count == Int(nameCount), Int(n) * 13 == bytes.count - at else { return nil }
        func column() -> [UInt32]? {
            guard let slice = take(Int(n) * 4) else { return nil }
            return slice.withUnsafeBytes { raw in
                [UInt32](unsafeUninitializedCapacity: Int(n)) { buf, count in
                    _ = memcpy(buf.baseAddress!, raw.baseAddress!, Int(n) * 4)
                    count = Int(n)
                }
            }
        }
        guard let name = column(), let end = column(), let items = column(), let f = take(Int(n)) else { return nil }
        let known = UInt32(names.count)
        for i in 0..<Int(n) {
            guard name[i] < known, Int(end[i]) > i, Int(end[i]) <= Int(n) else { return nil }
        }
        self.init(snapshotID: id, names: names, name: name, end: end, items: items, flags: Array(f))
    }

    public static func load(from url: URL) -> FolderIndex? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return FolderIndex(data: d)
    }

    /// Writes the index readable only by the user. The temporary file is in the same folder,
    /// so the final rename replaces the old index in one step.
    public func write(to url: URL) throws {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        let temp = dir.appendingPathComponent(".\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: temp.path, contents: data(), attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            _ = try fm.replaceItemAt(url, withItemAt: temp)
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
    }
}

/// Matches one path component against one component of a restic exclude pattern.
/// restic uses Go's filepath.Match, where `*` does not cross `/`. fnmatch behaves the same per component.
public enum FolderGlob {
    public static func match(_ pattern: String, _ name: String) -> Bool {
        fnmatch(pattern, name, 0) == 0
    }

    /// The plain text of a component without wildcards, or nil when it has any.
    static func literal(_ p: String) -> String? {
        var out = ""
        var escaped = false
        for ch in p {
            if escaped { out.append(ch); escaped = false; continue }
            if ch == "\\" { escaped = true; continue }
            if "*?[".contains(ch) { return nil }
            out.append(ch)
        }
        return out
    }

    /// True when an absolute pattern excludes the path: the pattern matches the path or one of its parents.
    public static func covers(_ pattern: String, _ path: String) -> Bool {
        guard pattern.hasPrefix("/") else { return false }
        let p = pattern.split(separator: "/"), x = path.split(separator: "/")
        guard p.count <= x.count, !p.isEmpty else { return false }
        return zip(p, x).allSatisfy { match(String($0), String($1)) }
    }
}
