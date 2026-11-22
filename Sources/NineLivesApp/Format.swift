import SwiftUI
import NineLivesCore

enum Fmt {
    static func bytes(_ n: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false
        return f.string(fromByteCount: n)
    }

    static func relative(_ d: Date) -> String {
        if abs(d.timeIntervalSinceNow) < 60 { return "just now" }
        return d.formatted(.relative(presentation: .named, unitsStyle: .wide))
    }

    static func duration(_ t: TimeInterval) -> String {
        let s = Int(t)
        if s < 60 { return "\(s) sec" }
        if s < 3600 { return "\(s / 60) min" }
        return "\(s / 3600) h \((s % 3600) / 60) min"
    }

    static func summary(_ stats: ArchiveStatsLike?) -> String {
        guard let stats else { return "" }
        return "\(stats.files.formatted()) files, \(bytes(stats.newBytes)) new"
    }
}

struct ArchiveStatsLike {
    var files: Int64
    var newBytes: Int64
}

extension BackupRecord {
    var statsLike: ArchiveStatsLike? {
        stats.map { ArchiveStatsLike(files: $0.fileCount, newBytes: $0.deduplicatedSize) }
    }
}

struct RelativeDateText: View {
    let date: Date
    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            Text(Fmt.relative(date))
        }
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct StatusSymbol: View {
    let status: OverallStatus
    var size: CGFloat = 44

    var body: some View {
        switch status {
        case .needsSetup: Image(systemName: "externaldrive.badge.plus").font(.system(size: size)).foregroundStyle(.secondary)
        case .running: ProgressView().controlSize(.large)
        case .ok: Image(systemName: "checkmark.circle.fill").font(.system(size: size)).foregroundStyle(.green)
        case .warning: Image(systemName: "exclamationmark.triangle.fill").font(.system(size: size)).foregroundStyle(.orange)
        case .error: Image(systemName: "xmark.octagon.fill").font(.system(size: size)).foregroundStyle(.red)
        }
    }
}

func statusTitle(_ status: OverallStatus) -> String {
    switch status {
    case .needsSetup: "Set up your first backup disk"
    case .running(let t): t
    case .ok: "Your Mac is backed up"
    case .warning(let t): t
    case .error: "The last backup failed"
    }
}

func revealInFinder(_ url: URL) {
    NSWorkspace.shared.activateFileViewerSelecting([url])
}


extension KnownDisk {
    func symbol(connected: Bool) -> String {
        isRemote ? (connected ? "server.rack" : "server.rack") : (connected ? "externaldrive.fill" : "externaldrive")
    }
    var offlineText: String { isRemote ? "Offline" : "Not connected" }
    var onlineText: String { isRemote ? "Online" : "Connected" }
}
