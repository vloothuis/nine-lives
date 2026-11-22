import Foundation
import BorgKit

/// The SSH key that Nine Lives uses to reach backup servers. It has no passphrase,
/// so scheduled backups work unattended. It is only valid for the servers where the user installed it.
public struct SSHKeyStore: Sendable {
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    public var privateKey: URL { directory.appendingPathComponent("id_ed25519") }
    public var publicKeyFile: URL { directory.appendingPathComponent("id_ed25519.pub") }
    public var knownHosts: URL { directory.appendingPathComponent("known_hosts") }

    public var options: SSHOptions { SSHOptions(keyFile: privateKey, knownHostsFile: knownHosts) }

    /// Creates the key pair on first use and returns the public key line to install on the server.
    @discardableResult
    public func ensureKey() throws -> String {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        if !fm.fileExists(atPath: privateKey.path) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
            p.arguments = ["-q", "-t", "ed25519", "-N", "", "-C", "Nine Lives on \(Machine.shortName)", "-f", privateKey.path]
            let err = Pipe()
            p.standardError = err
            p.standardOutput = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else {
                let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                throw SSHKeyError.generationFailed(msg.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        return try publicKey()
    }

    public func publicKey() throws -> String {
        let s = try String(contentsOf: publicKeyFile, encoding: .utf8)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum SSHKeyError: LocalizedError {
    case generationFailed(String)
    public var errorDescription: String? {
        switch self {
        case .generationFailed(let m): return "Could not create an SSH key. \(m)"
        }
    }
}
