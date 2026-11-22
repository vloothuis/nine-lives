import Foundation

public enum EncryptionMode: String, Codable, Sendable, CaseIterable {
    /// Integrity protection only. Used when the disk itself is encrypted.
    case authenticated = "authenticated-blake2"
    /// Full encryption with a passphrase. Used on unencrypted disks.
    case repokey = "repokey-blake2"
}

public struct Retention: Codable, Equatable, Sendable {
    public var hourly: Int
    public var daily: Int
    public var weekly: Int
    public var monthly: Int
    public var yearly: Int

    public init(hourly: Int = 24, daily: Int = 30, weekly: Int = 12, monthly: Int = 12, yearly: Int = 0) {
        self.hourly = hourly
        self.daily = daily
        self.weekly = weekly
        self.monthly = monthly
        self.yearly = yearly
    }

    public var arguments: [String] {
        var a: [String] = []
        if hourly > 0 { a += ["--keep-hourly", String(hourly)] }
        if daily > 0 { a += ["--keep-daily", String(daily)] }
        if weekly > 0 { a += ["--keep-weekly", String(weekly)] }
        if monthly > 0 { a += ["--keep-monthly", String(monthly)] }
        if yearly > 0 { a += ["--keep-yearly", String(yearly)] }
        return a
    }
}

/// A repository plus the passphrase needed to open it. Authenticated repos use an empty passphrase.
public struct BorgRepo: Sendable {
    public var url: URL
    public var passphrase: String
    /// For a repository on another machine: `ssh://user@host:port/path`. Overrides `url`.
    public var remote: String?
    /// Name or path of the borg executable on the server, when it is not `borg` on the default PATH.
    public var remotePath: String?

    public init(url: URL, passphrase: String = "") {
        self.url = url
        self.passphrase = passphrase
    }

    public init(remote: String, remotePath: String? = nil, passphrase: String = "") {
        self.url = URL(fileURLWithPath: "/")
        self.remote = remote
        self.remotePath = remotePath
        self.passphrase = passphrase
    }

    public var isRemote: Bool { remote != nil }
}

/// How borg reaches a server: a dedicated key and known hosts file.
public struct SSHOptions: Sendable {
    public var keyFile: URL
    public var knownHostsFile: URL
    public init(keyFile: URL, knownHostsFile: URL) {
        self.keyFile = keyFile
        self.knownHostsFile = knownHostsFile
    }

    /// Arguments for ssh. Never prompts, fails fast, ignores multiplexing, and notices dead connections.
    var arguments: [String] {
        ["-i", keyFile.path, "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes",
         "-o", "UserKnownHostsFile=" + knownHostsFile.path, "-o", "StrictHostKeyChecking=accept-new",
         "-o", "ControlMaster=no", "-o", "ControlPath=none", "-o", "GSSAPIAuthentication=no",
         "-o", "ConnectTimeout=15", "-o", "ServerAliveInterval=30", "-o", "ServerAliveCountMax=6"]
    }

    /// Value for BORG_RSH.
    var command: String {
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        return (["/usr/bin/ssh"] + arguments.map(q)).joined(separator: " ")
    }
}

public struct ArchiveStats: Codable, Equatable, Sendable {
    public var originalSize: Int64
    public var compressedSize: Int64
    public var deduplicatedSize: Int64
    public var fileCount: Int64

    public init(originalSize: Int64 = 0, compressedSize: Int64 = 0, deduplicatedSize: Int64 = 0, fileCount: Int64 = 0) {
        self.originalSize = originalSize
        self.compressedSize = compressedSize
        self.deduplicatedSize = deduplicatedSize
        self.fileCount = fileCount
    }
}

public struct ArchiveInfo: Identifiable, Equatable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var date: Date
    public init(id: String, name: String, date: Date) {
        self.id = id
        self.name = name
        self.date = date
    }
}

public struct RepositoryInfo: Sendable {
    public var id: String
    public var encryption: String
    /// Disk space used by the repository after compression and deduplication.
    public var storedSize: Int64
    /// Total size of all archives before deduplication.
    public var totalOriginalSize: Int64
}

public enum ArchiveItemType: String, Codable, Sendable {
    case file = "-"
    case directory = "d"
    case symlink = "l"
    case hardlink = "h"
    case other
}

public struct ArchiveItem: Sendable, Equatable {
    public var path: String
    public var type: ArchiveItemType
    public var size: Int64
    public var modified: Date?
    public var isHealthy: Bool
}

public struct CreateProgress: Sendable {
    public var fileCount: Int64
    public var originalSize: Int64
    public var compressedSize: Int64
    public var deduplicatedSize: Int64
    public var currentPath: String
}

public struct CreateOptions: Sendable {
    public var sources: [String]
    public var excludePatterns: [String]
    public var excludeCaches: Bool
    public var oneFileSystem: Bool
    public var excludeIfPresent: [String]
    public var compression: String

    public init(
        sources: [String],
        excludePatterns: [String] = [],
        excludeCaches: Bool = true,
        oneFileSystem: Bool = true,
        excludeIfPresent: [String] = [".nobackup"],
        compression: String = "zstd,3"
    ) {
        self.sources = sources
        self.excludePatterns = excludePatterns
        self.excludeCaches = excludeCaches
        self.oneFileSystem = oneFileSystem
        self.excludeIfPresent = excludeIfPresent
        self.compression = compression
    }
}

public struct CreateResult: Sendable {
    public var archiveID: String
    public var archiveName: String
    public var stats: ArchiveStats
    public var duration: TimeInterval
    /// Non-fatal problems, for example files that were unreadable or changed while being read.
    public var warnings: [String]
}

public struct CheckResult: Sendable {
    public var passed: Bool
    public var messages: [String]
}
