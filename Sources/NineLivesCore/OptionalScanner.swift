import Foundation

/// A large item that matches a rule Nine Lives skips until the user decides.
public struct OptionalItem: Identifiable, Equatable, Sendable {
    public var path: String
    public var size: Int64
    public var id: String { path }
}

/// All items found for one rule.
public struct OptionalFinding: Identifiable, Equatable, Sendable {
    /// The rule ID.
    public var id: String
    public var title: String
    public var items: [OptionalItem]
    public var size: Int64 { items.reduce(0) { $0 + $1.size } }
    public var paths: [String] { items.map(\.path) }
}

public enum OptionalScanner {
    /// Items smaller than this are not worth asking about.
    public static let minimumSize: Int64 = 2_000_000_000

    /// Looks for items that match the rules marked `ask` and have not been answered yet.
    /// Folder rules are checked directly. Rules like `*.pvm` are found with a shallow walk of the sources.
    public static func scan(
        rules: [ExcludeRule],
        answered: [String],
        answeredPaths: Set<String> = [],
        sources: [String],
        home: String = NSHomeDirectory(),
        minimumSize: Int64 = OptionalScanner.minimumSize,
        maxDepth: Int = 5
    ) -> [OptionalFinding] {
        let pending = rules.filter { $0.ask && $0.builtIn && !answered.contains($0.id) }
        let fm = FileManager.default
        var found: [String: [String]] = [:]

        func inSources(_ path: String) -> Bool {
            sources.contains { path == $0 || path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
        }

        for rule in pending {
            switch rule.kind {
            case .home, .absolute:
                let path = rule.kind == .home ? "\(home)/\(rule.value)" : rule.value
                if inSources(path), fm.fileExists(atPath: path) { found[rule.id, default: []].append(path) }
            case .anywhere, .marker:
                break
            }
        }

        let walked = pending.filter { $0.kind == .anywhere && $0.value.hasPrefix("*.") && !$0.value.dropFirst(2).contains("*") }
        if !walked.isEmpty {
            let suffixes = walked.map { (rule: $0, suffix: String($0.value.dropFirst(1))) }
            for source in sources {
                guard let e = fm.enumerator(
                    at: URL(fileURLWithPath: source), includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
                while let url = e.nextObject() as? URL {
                    if e.level > maxDepth { e.skipDescendants(); continue }
                    let name = url.lastPathComponent
                    if e.level == 1, name == "Library" { e.skipDescendants(); continue }
                    if let hit = suffixes.first(where: { name.hasSuffix($0.suffix) }) {
                        found[hit.rule.id, default: []].append(url.path)
                        e.skipDescendants()
                    }
                }
            }
        }

        var findings: [OptionalFinding] = []
        for rule in pending {
            guard let paths = found[rule.id] else { continue }
            let items = paths.sorted().filter { !answeredPaths.contains($0) }
                .map { OptionalItem(path: $0, size: allocatedSize(of: $0)) }
                .filter { $0.size >= minimumSize }
            if !items.isEmpty { findings.append(OptionalFinding(id: rule.id, title: rule.title, items: items)) }
        }
        return findings.sorted { $0.size > $1.size }
    }

    static func allocatedSize(of path: String) -> Int64 {
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        var total: Int64 = 0
        func add(_ u: URL) {
            let v = try? u.resourceValues(forKeys: keys)
            total += Int64(v?.totalFileAllocatedSize ?? v?.fileAllocatedSize ?? 0)
        }
        add(url)
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) else { return total }
        while let u = e.nextObject() as? URL { add(u) }
        return total
    }
}
