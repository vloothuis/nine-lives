import Foundation
import AppKit

public struct VolumeInfo: Identifiable, Equatable, Sendable {
    public var id: String { uuid }
    public var uuid: String
    public var url: URL
    public var name: String
    public var filesystem: String
    public var totalCapacity: Int64
    public var availableCapacity: Int64
    public var isEncrypted: Bool
    public var isInternal: Bool
    public var isWritable: Bool
    public var busProtocol: String

    /// Filesystems that handle a backup repository reliably.
    public var isSupportedFilesystem: Bool {
        ["apfs", "hfs", "exfat"].contains(filesystem.lowercased())
    }

    public var isExternal: Bool { !isInternal }
    public var filesystemDisplayName: String {
        switch filesystem.lowercased() {
        case "apfs": return "APFS"
        case "hfs": return "Mac OS Extended"
        case "exfat": return "ExFAT"
        case "msdos": return "FAT"
        case "ntfs": return "NTFS"
        default: return filesystem.uppercased()
        }
    }
}

public enum VolumeInspector {
    static func diskutilInfo(path: String) -> [String: Any]? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        p.arguments = ["info", "-plist", path]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    public static func inspect(url: URL) -> VolumeInfo? {
        guard let info = diskutilInfo(path: url.path) else { return nil }
        guard let uuid = info["VolumeUUID"] as? String else { return nil }
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeIsReadOnlyKey]
        let values = try? url.resourceValues(forKeys: keys)
        let encrypted = (info["Encryption"] as? Bool ?? false)
            || (info["FileVault"] as? Bool ?? false)
            || (info["Encrypted"] as? Bool ?? false)
        return VolumeInfo(
            uuid: uuid,
            url: url,
            name: (info["VolumeName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? url.lastPathComponent,
            filesystem: info["FilesystemType"] as? String ?? "unknown",
            totalCapacity: Int64(values?.volumeTotalCapacity ?? (info["TotalSize"] as? Int ?? 0)),
            availableCapacity: values?.volumeAvailableCapacityForImportantUsage
                ?? Int64(info["FreeSpace"] as? Int ?? 0),
            isEncrypted: encrypted,
            isInternal: info["Internal"] as? Bool ?? true,
            isWritable: (info["WritableVolume"] as? Bool ?? true) && !(values?.volumeIsReadOnly ?? false),
            busProtocol: info["BusProtocol"] as? String ?? "")
    }

    /// Mounted volumes that could serve as backup disks.
    public static func externalVolumes() -> [VolumeInfo] {
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeIsLocalKey, .volumeIsRootFileSystemKey],
            options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            guard url.path.hasPrefix("/Volumes/") else { return nil }
            let v = try? url.resourceValues(forKeys: [.volumeIsLocalKey, .volumeIsRootFileSystemKey])
            guard v?.volumeIsLocal == true, v?.volumeIsRootFileSystem != true else { return nil }
            guard let info = inspect(url: url), info.isExternal else { return nil }
            if info.busProtocol == "Disk Image", ProcessInfo.processInfo.environment["NINELIVES_ALLOW_DISK_IMAGES"] == nil {
                return nil
            }
            return info
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

/// Watches for volumes appearing and disappearing.
@MainActor
@Observable
public final class DiskMonitor {
    public private(set) var volumes: [VolumeInfo] = []
    /// False until the first scan has finished.
    public private(set) var loaded = false
    /// Called for volumes that appear after monitoring started.
    @ObservationIgnored public var onMount: ((VolumeInfo) -> Void)?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var started = false
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    public init() {}

    public func start() {
        guard !started else { return }
        started = true
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.scheduleRefresh() }
            })
        }
        Task { await refresh(announce: false) }
    }

    public func volume(withID id: String) -> VolumeInfo? { volumes.first { $0.id == id } }

    public func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task {
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            await refresh(announce: true)
        }
    }

    public func refresh(announce: Bool) async {
        let found = await Task.detached { VolumeInspector.externalVolumes() }.value
        let oldIDs = Set(volumes.map(\.id))
        volumes = found
        loaded = true
        if announce {
            for v in found where !oldIDs.contains(v.id) { onMount?(v) }
        }
    }
}
