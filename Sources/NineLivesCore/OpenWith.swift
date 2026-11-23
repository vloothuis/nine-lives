import Foundation

/// Sets Finder's per-file "Open with" choice, so double-clicking a file opens Nine Lives.
///
/// Finder stores this choice in the `com.apple.LaunchServices.OpenWith` extended attribute.
/// The format is not documented, so failures are ignored. Without the attribute, or on a Mac
/// without Nine Lives, the file opens in the default app as usual.
public enum OpenWith {
    static let attributeName = "com.apple.LaunchServices.OpenWith"

    /// The value for an app bundle, or nil when not running from one (tests, `swift run`).
    static func value(for bundle: Bundle) -> Data? {
        guard bundle.bundleURL.pathExtension == "app", let id = bundle.bundleIdentifier else { return nil }
        let dict: [String: Any] = ["version": 0, "bundleidentifier": id, "path": bundle.bundleURL.path]
        return try? PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0)
    }

    /// Makes the file open with the running app. Does nothing when the file is missing.
    public static func set(on file: URL, bundle: Bundle = .main) {
        guard let data = value(for: bundle), FileManager.default.fileExists(atPath: file.path) else { return }
        _ = data.withUnsafeBytes { buf in
            setxattr(file.path, attributeName, buf.baseAddress, buf.count, 0, 0)
        }
    }
}
