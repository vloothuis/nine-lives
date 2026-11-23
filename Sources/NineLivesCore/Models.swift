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
        /// A file name. Any folder that contains this file is skipped.
        case marker
    }

    public var id: String
    public var title: String
    public var detail: String
    public var kind: Kind
    public var value: String
    public var enabled: Bool
    public var builtIn: Bool
    /// Group heading in Settings.
    public var category: String
    /// Large items that match this rule are skipped until the user decides, and Nine Lives asks after a backup.
    public var ask: Bool

    public init(id: String, title: String, detail: String, kind: Kind, value: String, enabled: Bool = true,
                builtIn: Bool = true, category: String = ExcludeRule.defaultCategory, ask: Bool = false) {
        self.id = id
        self.title = title
        self.detail = detail
        self.kind = kind
        self.value = value
        self.enabled = enabled
        self.builtIn = builtIn
        self.category = category
        self.ask = ask
    }

    public static let defaultCategory = "Your own choices"

    /// Files written by older versions have no category.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        detail = try c.decode(String.self, forKey: .detail)
        kind = try c.decode(Kind.self, forKey: .kind)
        value = try c.decode(String.self, forKey: .value)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        builtIn = try c.decode(Bool.self, forKey: .builtIn)
        category = try c.decodeIfPresent(String.self, forKey: .category) ?? Self.defaultCategory
        ask = try c.decodeIfPresent(Bool.self, forKey: .ask) ?? false
    }

    /// The restic exclude pattern for this rule. A pattern without a leading slash matches at any depth. Marker rules have none.
    public func pattern(home: String) -> String? {
        switch kind {
        case .home: return "\(home)/\(value)"
        case .anywhere: return value
        case .absolute: return value
        case .marker: return nil
        }
    }
}

public enum DefaultRules {
    /// Every built-in rule, grouped by category in Settings.
    public static let all: [ExcludeRule] = core + developer + macOS

    private static let core: [ExcludeRule] = [
        ExcludeRule(id: "caches", title: "App caches", detail: "Temporary files that apps rebuild by themselves.",
                    kind: .anywhere, value: "Library/Caches", category: "System and apps"),
        ExcludeRule(id: "dotcache", title: "Command line caches", detail: "The hidden .cache folder.",
                    kind: .home, value: ".cache", category: "System and apps"),
        ExcludeRule(id: "logs", title: "Logs", detail: "System and app log files.",
                    kind: .home, value: "Library/Logs", category: "System and apps"),
        ExcludeRule(id: "trash", title: "Trash", detail: "Items you already deleted.",
                    kind: .home, value: ".Trash", category: "System and apps"),
        ExcludeRule(id: "cloud", title: "Cloud storage folders",
                    detail: "Dropbox, Google Drive and similar. These live in the cloud already, and reading them would download everything. They are not part of your backup.",
                    kind: .home, value: "Library/CloudStorage", category: "Cloud storage"),
        ExcludeRule(id: "icloud", title: "iCloud Drive",
                    detail: "Already stored in iCloud. Reading it would download files that are not on this Mac. It is not part of your backup.",
                    kind: .home, value: "Library/Mobile Documents", category: "Cloud storage"),
        ExcludeRule(id: "docker", title: "Docker data",
                    detail: "Large container images that can be downloaded again. Data in Docker volumes is skipped too.",
                    kind: .home, value: "Library/Containers/com.docker.docker", category: "Virtual machines and containers", ask: true),
        ExcludeRule(id: "vms", title: "Parallels machines", detail: "Parallels disk images are very large.",
                    kind: .anywhere, value: "*.pvm", category: "Virtual machines and containers", ask: true),
        ExcludeRule(id: "vmware", title: "VMware machines", detail: "VMware Fusion disk images are very large.",
                    kind: .anywhere, value: "*.vmwarevm", category: "Virtual machines and containers", ask: true),
        ExcludeRule(id: "utm", title: "UTM machines", detail: "UTM disk images are very large.", kind: .home,
                    value: "Library/Containers/com.utmapp.UTM", category: "Virtual machines and containers", ask: true),
        ExcludeRule(id: "node", title: "node_modules", detail: "JavaScript dependencies that npm can restore.",
                    kind: .anywhere, value: "node_modules", category: "JavaScript and TypeScript"),
        ExcludeRule(id: "xcode", title: "Xcode build data", detail: "DerivedData, rebuilt by Xcode.",
                    kind: .home, value: "Library/Developer/Xcode/DerivedData", category: "Swift and Xcode"),
        ExcludeRule(id: "simulators", title: "Xcode simulators", detail: "Simulator runtimes and devices.", kind: .home,
                    value: "Library/Developer/CoreSimulator", category: "Swift and Xcode"),
        ExcludeRule(id: "pkgcaches", title: "npm cache", detail: "Downloaded again by npm.",
                    kind: .home, value: ".npm", category: "JavaScript and TypeScript"),
        ExcludeRule(id: "gradle", title: "Gradle cache", detail: "Downloaded again by Gradle.", kind: .home,
                    value: ".gradle/caches", category: "Java, Kotlin and Scala"),
        ExcludeRule(id: "maven", title: "Maven repository",
                    detail: "Downloaded again by Maven. Artifacts you only installed locally are skipped too.",
                    kind: .home, value: ".m2/repository", category: "Java, Kotlin and Scala"),
        ExcludeRule(id: "cargo", title: "Cargo registry", detail: "Downloaded again by Cargo.", kind: .home,
                    value: ".cargo/registry", category: "Rust"),
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
    /// Rules the user has already answered, so Nine Lives does not ask again.
    public var answeredRuleIDs: [String]
    /// Answers for single items: true backs the path up, false skips it. They win over the rules.
    public var pathChoices: [String: Bool]

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
        enginePathOverride: String? = nil,
        answeredRuleIDs: [String] = [],
        pathChoices: [String: Bool] = [:]
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
        self.answeredRuleIDs = answeredRuleIDs
        self.pathChoices = pathChoices
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
        answeredRuleIDs = try c.decodeIfPresent([String].self, forKey: .answeredRuleIDs) ?? []
        pathChoices = try c.decodeIfPresent([String: Bool].self, forKey: .pathChoices) ?? [:]
    }

    public func excludePatterns(home: String = NSHomeDirectory()) -> [String] {
        let skipped = pathChoices.filter { !$0.value }.keys.sorted()
        return (rules.filter(\.enabled) + DefaultRules.always).compactMap { $0.pattern(home: home) } + skipped
    }

    /// Paths the user chose to back up although a rule skips them.
    public var includePatterns: [String] {
        pathChoices.filter(\.value).keys.sorted()
    }

    /// File names that make restic skip the folder that holds them.
    public var excludeMarkers: [String] {
        rules.filter { $0.enabled && $0.kind == .marker }.map(\.value)
    }

    /// Adds rules introduced in newer versions and keeps the user's choices for the rest.
    public mutating func mergeDefaultRules() {
        for d in DefaultRules.all {
            if let i = rules.firstIndex(where: { $0.id == d.id }) {
                if rules[i].builtIn { rules[i].category = d.category; rules[i].ask = d.ask }
            } else {
                rules.append(d)
            }
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

/// Files spread over one snapshot, recorded while the backup ran.
public struct BackupSample: Codable, Equatable, Sendable {
    public var snapshotID: String
    public var files: [SampledFile]

    public init(snapshotID: String, files: [SampledFile]) {
        self.snapshotID = snapshotID
        self.files = files
    }

    /// Up to `count` files spread evenly over the sample.
    public func spread(count: Int) -> [SampledFile] {
        guard files.count > count, count > 0 else { return files }
        return (0..<count).map { files[$0 * files.count / count] }
    }
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
    /// Files picked during the last backup, so verification can test restores without listing the whole snapshot.
    public var lastBackupSample: BackupSample?
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
    /// Set once Full Disk Access has been seen, so losing it later (for example after an update) can be detected.
    public var hadFullDiskAccess = false

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        settings = try c.decodeIfPresent(BackupSettings.self, forKey: .settings) ?? BackupSettings()
        disks = try c.decodeIfPresent([KnownDisk].self, forKey: .disks) ?? []
        history = try c.decodeIfPresent([BackupRecord].self, forKey: .history) ?? []
        onboardingComplete = try c.decodeIfPresent(Bool.self, forKey: .onboardingComplete) ?? false
        lastStaleReminder = try c.decodeIfPresent(Date.self, forKey: .lastStaleReminder)
        hadFullDiskAccess = try c.decodeIfPresent(Bool.self, forKey: .hadFullDiskAccess) ?? false
    }
}
