import Foundation

/// How a backup is protected. The raw values come from the borg era and stay for saved state.
public enum EncryptionMode: String, Codable, Sendable, CaseIterable {
    /// The disk itself is encrypted. The repository password is generated and stored next to the backups.
    case authenticated = "authenticated-blake2"
    /// The user's recovery passphrase is the repository password.
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

/// A server reached over SSH, as restic needs it.
public struct SFTPLocation: Sendable, Equatable {
    public var host: String
    public var port: Int
    public var user: String
    /// Folder on the server. Without a leading slash it is relative to the user's home folder.
    public var path: String

    public init(host: String, port: Int, user: String, path: String) {
        self.host = host
        self.port = port
        self.user = user
        self.path = path
    }

    /// The repository location in restic's `sftp:` syntax.
    var repository: String {
        let h = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        return "sftp:\(user)@\(h):\(path)"
    }
}

/// A repository plus the password needed to open it.
public struct ResticRepo: Sendable {
    public var url: URL
    public var password: String
    public var remote: SFTPLocation?

    public init(url: URL, password: String) {
        self.url = url
        self.password = password
    }

    public init(remote: SFTPLocation, password: String) {
        self.url = URL(fileURLWithPath: "/")
        self.remote = remote
        self.password = password
    }

    public var isRemote: Bool { remote != nil }
    var location: String { remote?.repository ?? url.path }
}

/// How restic and plain ssh reach a server: a dedicated key and known hosts file.
public struct SSHOptions: Sendable {
    public var keyFile: URL
    public var knownHostsFile: URL
    public init(keyFile: URL, knownHostsFile: URL) {
        self.keyFile = keyFile
        self.knownHostsFile = knownHostsFile
    }

    /// Arguments for ssh. Never prompts, fails fast, ignores multiplexing, and notices dead connections.
    var arguments: [String] {
        ["-i", keyFile.path, "-o", "IdentitiesOnly=yes", "-o", "IdentityAgent=none", "-o", "BatchMode=yes",
         "-o", "UserKnownHostsFile=" + knownHostsFile.path, "-o", "StrictHostKeyChecking=accept-new",
         "-o", "ControlMaster=no", "-o", "ControlPath=none", "-o", "GSSAPIAuthentication=no",
         "-o", "ConnectTimeout=15", "-o", "ServerAliveInterval=30", "-o", "ServerAliveCountMax=6"]
    }

    /// The ssh command that starts SFTP on the server, as separate arguments.
    func sftpArguments(_ remote: SFTPLocation) -> [String] {
        ["/usr/bin/ssh"] + arguments + ["-p", String(remote.port), "\(remote.user)@\(remote.host)", "-s", "sftp"]
    }

    /// Value for restic's `sftp.command` option.
    func sftpCommand(_ remote: SFTPLocation) -> String {
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        return sftpArguments(remote).map(q).joined(separator: " ")
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

/// One snapshot. `id` is the full snapshot ID, `name` the short ID.
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

public enum ArchiveItemType: String, Codable, Sendable {
    case file = "-"
    case directory = "d"
    case symlink = "l"
    case hardlink = "h"
    case other
}

public struct ArchiveItem: Sendable, Equatable {
    /// Path without a leading slash, for example `Users/me/a.txt`.
    public var path: String
    public var type: ArchiveItemType
    public var size: Int64
    public var modified: Date?
}

public struct CreateProgress: Sendable {
    public var fileCount: Int64
    public var originalSize: Int64
    /// Bytes added to the repository so far. restic only reports this at the end, so it is 0 while running.
    public var deduplicatedSize: Int64
    /// Always nil: restic runs with `--no-scan`, so it has no total to report.
    public var fraction: Double?
    public var currentPath: String
}

public struct CreateOptions: Sendable {
    public var sources: [String]
    public var excludePatterns: [String]
    /// Paths that stay in the backup although an exclude pattern matches them. Passed to restic as negated excludes.
    public var includePatterns: [String]
    public var excludeCaches: Bool
    public var oneFileSystem: Bool
    public var excludeIfPresent: [String]
    /// Folder names that nl-engine skips where Git ignores them. restic has no such option.
    public var excludeGitignored: [String]
    /// Stable host name, so restic finds the previous snapshot even when the Mac is renamed.
    public var host: String?
    public var tag: String
    /// How many files restic reads at the same time.
    public var readConcurrency: Int

    public init(
        sources: [String],
        excludePatterns: [String] = [],
        includePatterns: [String] = [],
        excludeCaches: Bool = true,
        oneFileSystem: Bool = true,
        excludeIfPresent: [String] = [".nobackup"],
        excludeGitignored: [String] = [],
        host: String? = nil,
        tag: String = "ninelives",
        readConcurrency: Int = 8
    ) {
        self.sources = sources
        self.excludePatterns = excludePatterns
        self.includePatterns = includePatterns
        self.excludeCaches = excludeCaches
        self.oneFileSystem = oneFileSystem
        self.excludeIfPresent = excludeIfPresent
        self.excludeGitignored = excludeGitignored
        self.host = host
        self.tag = tag
        self.readConcurrency = readConcurrency
    }
}

public struct CreateResult: Sendable {
    public var archiveID: String
    public var archiveName: String
    public var stats: ArchiveStats
    public var duration: TimeInterval
    /// Non-fatal problems, for example files that were unreadable.
    public var warnings: [String]
    /// Files spread over the snapshot, used to test restores without listing the whole snapshot.
    public var sample: [SampledFile] = []
    /// The folder tree of the backup, or nil when it was too large to collect.
    public var folders: FolderCollector?
}

public struct CheckResult: Sendable {
    public var passed: Bool
    public var messages: [String]
}
