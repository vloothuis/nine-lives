import Foundation
import ResticKit

// MARK: - Exclusion rules

public struct ExcludeRule: Codable, Identifiable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// Path relative to the home folder.
        case home
        /// A file or folder name that is skipped wherever it appears.
        case anywhere
        /// An absolute path.
        case absolute
    }

    public var id: String
    public var title: String
    public var detail: String
    public var kind: Kind
    public var value: String
    public var enabled: Bool
    public var builtIn: Bool

    public init(id: String, title: String, detail: String, kind: Kind, value: String, enabled: Bool = true, builtIn: Bool = true) {
        self.id = id
        self.title = title
        self.detail = detail
        self.kind = kind
        self.value = value
        self.enabled = enabled
        self.builtIn = builtIn
    }

    /// The restic exclude pattern for this rule. A pattern without a leading slash matches at any depth.
    public func pattern(home: String) -> String {
        switch kind {
        case .home: return "\(home)/\(value)"
        case .anywhere: return value
        case .absolute: return value
        }
    }
}

public enum DefaultRules {
    public static let all: [ExcludeRule] = [
        ExcludeRule(id: "caches", title: "App caches", detail: "Temporary files that apps rebuild by themselves.",
                    kind: .anywhere, value: "Library/Caches"),
        ExcludeRule(id: "dotcache", title: "Command line caches", detail: "The hidden .cache folder.",
                    kind: .home, value: ".cache"),
        ExcludeRule(id: "logs", title: "Logs", detail: "System and app log files.",
                    kind: .home, value: "Library/Logs"),
        ExcludeRule(id: "trash", title: "Trash", detail: "Items you already deleted.",
                    kind: .home, value: ".Trash"),
        ExcludeRule(id: "cloud", title: "Cloud storage folders",
                    detail: "Dropbox, Google Drive and similar. These live in the cloud already, and reading them would download everything.",
                    kind: .home, value: "Library/CloudStorage"),
        ExcludeRule(id: "icloud", title: "iCloud Drive",
                    detail: "Already stored in iCloud. Reading it would download files that are not on this Mac.",
                    kind: .home, value: "Library/Mobile Documents"),
        ExcludeRule(id: "docker", title: "Docker data", detail: "Large container images that can be downloaded again.",
                    kind: .home, value: "Library/Containers/com.docker.docker"),
        ExcludeRule(id: "vms", title: "Virtual machines", detail: "Parallels, VMware and UTM disk images are very large.",
                    kind: .anywhere, value: "*.pvm"),
        ExcludeRule(id: "vmware", title: "VMware machines", detail: "", kind: .anywhere, value: "*.vmwarevm"),
        ExcludeRule(id: "utm", title: "UTM machines", detail: "", kind: .home,
                    value: "Library/Containers/com.utmapp.UTM"),
        ExcludeRule(id: "node", title: "node_modules", detail: "JavaScript dependencies that npm can restore.",
                    kind: .anywhere, value: "node_modules"),
        ExcludeRule(id: "xcode", title: "Xcode build data", detail: "DerivedData and simulators.",
                    kind: .home, value: "Library/Developer/Xcode/DerivedData"),
        ExcludeRule(id: "simulators", title: "Xcode simulators", detail: "", kind: .home,
                    value: "Library/Developer/CoreSimulator"),
        ExcludeRule(id: "pkgcaches", title: "Package manager caches",
                    detail: "npm, Gradle, Maven and Cargo download caches.",
                    kind: .home, value: ".npm"),
        ExcludeRule(id: "gradle", title: "Gradle cache", detail: "", kind: .home, value: ".gradle/caches"),
        ExcludeRule(id: "maven", title: "Maven repository", detail: "", kind: .home, value: ".m2/repository"),
        ExcludeRule(id: "cargo", title: "Cargo registry", detail: "", kind: .home, value: ".cargo/registry"),
    ]

    /// Rules that are always applied and not shown as choices.
    public static let always: [ExcludeRule] = [
        ExcludeRule(id: "own-data", title: "Nine Lives working files", detail: "",
                    kind: .home, value: "Library/Application Support/Nine Lives/Restic"),
        ExcludeRule(id: "own-catalog", title: "Nine Lives catalogs", detail: "",
                    kind: .home, value: "Library/Application Support/Nine Lives/Catalogs"),
    ]
}

// MARK: - Settings

public struct BackupSettings: Codable, Equatable, Sendable {
    public var sources: [String]
    public var rules: [ExcludeRule]
    public var retention: Retention
    /// Minutes between backups while a disk stays connected.
    public var intervalMinutes: Int
    public var ejectAfterPlugIn: Bool
    public var notifyOnSuccess: Bool
    public var remindAfterDays: Int
    public var verifyEveryDays: Int
    public var pauseOnLowBattery: Bool
    public var enginePathOverride: String?

    public init(
        sources: [String] = [NSHomeDirectory()],
        rules: [ExcludeRule] = DefaultRules.all,
        retention: Retention = Retention(),
        intervalMinutes: Int = 60,
        ejectAfterPlugIn: Bool = true,
        notifyOnSuccess: Bool = true,
        remindAfterDays: Int = 7,
        verifyEveryDays: Int = 30,
        pauseOnLowBattery: Bool = true,
        enginePathOverride: String? = nil
    ) {
        self.sources = sources
        self.rules = rules
        self.retention = retention
        self.intervalMinutes = intervalMinutes
        self.ejectAfterPlugIn = ejectAfterPlugIn
        self.notifyOnSuccess = notifyOnSuccess
        self.remindAfterDays = remindAfterDays
        self.verifyEveryDays = verifyEveryDays
        self.pauseOnLowBattery = pauseOnLowBattery
        self.enginePathOverride = enginePathOverride
    }

    /// Missing keys fall back to defaults, so files written by older versions keep loading.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = BackupSettings()
        sources = try c.decodeIfPresent([String].self, forKey: .sources) ?? d.sources
        rules = try c.decodeIfPresent([ExcludeRule].self, forKey: .rules) ?? d.rules
        retention = try c.decodeIfPresent(Retention.self, forKey: .retention) ?? d.retention
        intervalMinutes = try c.decodeIfPresent(Int.self, forKey: .intervalMinutes) ?? d.intervalMinutes
        ejectAfterPlugIn = try c.decodeIfPresent(Bool.self, forKey: .ejectAfterPlugIn) ?? d.ejectAfterPlugIn
        notifyOnSuccess = try c.decodeIfPresent(Bool.self, forKey: .notifyOnSuccess) ?? d.notifyOnSuccess
        remindAfterDays = try c.decodeIfPresent(Int.self, forKey: .remindAfterDays) ?? d.remindAfterDays
        verifyEveryDays = try c.decodeIfPresent(Int.self, forKey: .verifyEveryDays) ?? d.verifyEveryDays
        pauseOnLowBattery = try c.decodeIfPresent(Bool.self, forKey: .pauseOnLowBattery) ?? d.pauseOnLowBattery
        // An override saved by older versions points at borg, so it is not read here.
        enginePathOverride = try c.decodeIfPresent(String.self, forKey: .enginePathOverride)
    }

    public func excludePatterns(home: String = NSHomeDirectory()) -> [String] {
        (rules.filter(\.enabled) + DefaultRules.always).map { $0.pattern(home: home) }
    }

    /// Adds rules introduced in newer versions and keeps the user's choices for the rest.
    public mutating func mergeDefaultRules() {
        for d in DefaultRules.all where !rules.contains(where: { $0.id == d.id }) {
            rules.append(d)
        }
    }
}

// MARK: - Disks and history

public enum RepositoryFormat: String, Codable, Sendable {
    case borg, restic
}

public struct VerificationSummary: Codable, Equatable, Sendable {
    public var date: Date
    public var repositoryOK: Bool
    public var filesRestored: Int
    public var problems: [String]
    public var passed: Bool { repositoryOK && problems.isEmpty }
}

/// A server that holds a backup repository, reached over SSH.
public struct RemoteServer: Codable, Equatable, Sendable {
    public var host: String
    public var user: String
    public var port: Int
    /// Folder on the server. A path without a leading slash is relative to the user's home folder.
    public var path: String

    public init(host: String, user: String, port: Int = 22, path: String) {
        self.host = host
        self.user = user
        self.port = port
        self.path = path
    }

    /// The location as restic reaches it over SFTP.
    public var location: SFTPLocation { SFTPLocation(host: host, port: port, user: user, path: path) }

    public var display: String { "\(user)@\(host)" }

    public static var defaultPath: String { "nine-lives/\(Machine.folderName)" }
}

public struct KnownDisk: Codable, Identifiable, Equatable, Sendable {
    /// The volume UUID.
    public var id: String
    public var name: String
    public var mode: EncryptionMode
    public var diskEncrypted: Bool
    /// Location of the repository, relative to the volume root.
    public var repoFolder: String
    public var addedAt: Date
    public var lastBackup: Date?
    public var lastBackupStats: ArchiveStats?
    public var lastBackupDuration: TimeInterval?
    public var lastVerification: VerificationSummary?
    public var capacity: Int64?
    public var storedSize: Int64?
    /// Set for backups on a server instead of a disk.
    public var remote: RemoteServer?
    /// When the last scheduled attempt failed. Used to wait before trying again.
    public var lastFailure: Date?
    /// The repository ID seen when the disk was added. A different ID means the repository was replaced.
    public var repositoryID: String?
    /// Storage format. Missing in state from versions that used borg.
    public var format: RepositoryFormat?
    /// While switching from borg: the folder of the old borg backups, removed after the first restic backup.
    public var legacyFolder: String?

    public var isRemote: Bool { remote != nil }
    public var needsMigration: Bool { format != .restic }

    public init(
        id: String, name: String, mode: EncryptionMode, diskEncrypted: Bool, repoFolder: String,
        addedAt: Date = Date(), capacity: Int64? = nil
    ) {
        self.id = id
        self.name = name
        self.mode = mode
        self.diskEncrypted = diskEncrypted
        self.repoFolder = repoFolder
        self.addedAt = addedAt
        self.capacity = capacity
        self.format = .restic
    }

    public init(server: RemoteServer, name: String? = nil) {
        self.init(id: UUID().uuidString, name: name ?? server.host, mode: .repokey, diskEncrypted: false, repoFolder: "")
        self.remote = server
    }
}

public enum BackupTrigger: String, Codable, Sendable {
    case manual, plugIn, scheduled
}

public struct BackupRecord: Codable, Identifiable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable { case success, warning, failed, cancelled }

    public var id: UUID
    public var diskID: String
    public var diskName: String
    public var start: Date
    public var end: Date
    public var outcome: Outcome
    public var archiveName: String?
    public var stats: ArchiveStats?
    public var messages: [String]
    /// Technical output of a failure, shown on request.
    public var details: String?
    public var trigger: BackupTrigger

    public init(
        id: UUID = UUID(), diskID: String, diskName: String, start: Date, end: Date, outcome: Outcome,
        archiveName: String? = nil, stats: ArchiveStats? = nil, messages: [String] = [], trigger: BackupTrigger
    ) {
        self.id = id
        self.diskID = diskID
        self.diskName = diskName
        self.start = start
        self.end = end
        self.outcome = outcome
        self.archiveName = archiveName
        self.stats = stats
        self.messages = messages
        self.trigger = trigger
    }
}

public struct AppState: Codable, Equatable, Sendable {
    public var settings = BackupSettings()
    public var disks: [KnownDisk] = []
    public var history: [BackupRecord] = []
    public var onboardingComplete = false
    public var lastStaleReminder: Date?

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        settings = try c.decodeIfPresent(BackupSettings.self, forKey: .settings) ?? BackupSettings()
        disks = try c.decodeIfPresent([KnownDisk].self, forKey: .disks) ?? []
        history = try c.decodeIfPresent([BackupRecord].self, forKey: .history) ?? []
        onboardingComplete = try c.decodeIfPresent(Bool.self, forKey: .onboardingComplete) ?? false
        lastStaleReminder = try c.decodeIfPresent(Date.self, forKey: .lastStaleReminder)
    }
}
