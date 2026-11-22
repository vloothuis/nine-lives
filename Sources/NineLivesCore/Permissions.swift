import Foundation
import AppKit

public enum Permissions {
    /// Full Disk Access shows up as the ability to read the TCC database.
    public static func hasFullDiskAccess() -> Bool {
        let fd = open("/Library/Application Support/com.apple.TCC/TCC.db", O_RDONLY)
        if fd >= 0 { close(fd); return true }
        return false
    }

    public static func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    /// nil when the state cannot be determined.
    public static func isFileVaultOn() -> Bool? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/fdesetup")
        p.arguments = ["isactive"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        switch out.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }
}

public enum Machine {
    /// A stable folder name for this Mac, so several Macs can share one disk.
    public static var folderName: String {
        let name = Host.current().localizedName ?? "Mac"
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_."))
        let clean = String(name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
        let short = String(hardwareUUID.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
        return "\(clean)-\(short)"
    }

    /// The Mac's name without the hardware suffix, for labels.
    public static var shortName: String { Host.current().localizedName ?? "Mac" }

    static var hardwareUUID: String {
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        defer { IOObjectRelease(entry) }
        guard entry != 0,
              let prop = IORegistryEntryCreateCFProperty(entry, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String else { return "unknown" }
        return prop
    }
}
