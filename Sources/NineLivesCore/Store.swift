import Foundation

/// Persists `AppState` as JSON in Application Support.
public final class StateStore: @unchecked Sendable {
    public let directory: URL
    private let fileURL: URL
    private let lock = NSLock()

    public static var defaultDirectory: URL {
        // Lets demos and screenshots run with their own state.
        if let path = ProcessInfo.processInfo.environment["NINELIVES_STATE_DIR"] {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Nine Lives", isDirectory: true)
    }

    public init(directory: URL = StateStore.defaultDirectory) {
        self.directory = directory
        self.fileURL = directory.appendingPathComponent("state.json")
    }

    public func load() -> AppState {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: fileURL) else { return AppState() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var state = (try? decoder.decode(AppState.self, from: data)) ?? AppState()
        state.settings.mergeDefaultRules()
        return state
    }

    public func save(_ state: AppState) {
        lock.lock(); defer { lock.unlock() }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(state).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("Nine Lives: could not save state: \(error)")
        }
    }

    public var cacheDirectory: URL { directory.appendingPathComponent("Restic", isDirectory: true) }
    /// Working files of the borg versions. Removed on start.
    public var legacyBorgDirectory: URL { directory.appendingPathComponent("Borg", isDirectory: true) }
    public var sshDirectory: URL { directory.appendingPathComponent("SSH", isDirectory: true) }
    public var catalogDirectory: URL { directory.appendingPathComponent("Catalogs", isDirectory: true) }
}
