import Foundation

public struct ResticError: LocalizedError, Sendable {
    public var exitCode: Int32
    public var messages: [String]
    /// Unstructured output, for example errors printed by ssh.
    public var rawMessages: [String]

    public init(exitCode: Int32, messages: [String] = [], rawMessages: [String] = []) {
        self.exitCode = exitCode
        self.messages = messages
        self.rawMessages = rawMessages
    }

    private var everything: [String] { messages + rawMessages }
    private func mentions(_ needles: [String]) -> Bool {
        everything.contains { line in needles.contains { line.localizedCaseInsensitiveContains($0) } }
    }

    /// The server rejected our key or the user does not exist.
    public var isAuthenticationFailure: Bool { mentions(["permission denied (publickey"]) }

    /// The server could not be reached at all.
    public var isConnectionProblem: Bool {
        if isAuthenticationFailure { return true }
        return mentions(["could not resolve", "connection refused", "connection timed out", "operation timed out",
                         "no route to host", "network is unreachable", "connection closed", "connection reset",
                         "broken pipe", "host key verification failed", "name or service not known",
                         "nodename nor servname", "unable to start the sftp session"])
    }

    /// ssh worked but the server does not offer SFTP.
    public var isSFTPMissing: Bool { mentions(["subsystem request failed"]) }

    public var errorDescription: String? { summary }

    /// A short sentence for people. Technical output is in `details`.
    public var summary: String {
        if isWrongPassphrase { return "The saved passphrase does not match." }
        if isOutOfSpace { return "The backup location is full." }
        if isSFTPMissing { return "The server does not offer SFTP, which Nine Lives needs." }
        if isAuthenticationFailure { return "The server did not accept the Nine Lives key." }
        if isConnectionProblem { return "Could not reach the server." }
        let lines = everything.filter { !$0.isEmpty }
        if lines.count == 1, let one = lines.first, one.count <= 160 { return one.replacingOccurrences(of: "Fatal: ", with: "") }
        return "restic reported an error (code \(exitCode))."
    }

    /// The full technical output, for the Details view and for copying.
    public var details: String? {
        let text = everything.filter { !$0.isEmpty }.joined(separator: "\n")
        return text.isEmpty || text == summary ? nil : text
    }

    public var isCancelled: Bool { exitCode == 130 }
    public var isWrongPassphrase: Bool { exitCode == 12 }
    public var isLockProblem: Bool { exitCode == 11 }
    public var isRepositoryMissing: Bool { exitCode == 10 }
    public var isOutOfSpace: Bool { mentions(["no space left"]) }
}

/// Classification of restic's exit codes.
public enum ResticExit: Equatable, Sendable {
    case success
    /// The snapshot was made, but some files could not be read.
    case warning
    case failure
    case cancelled

    public init(code: Int32) {
        switch code {
        case 0: self = .success
        case 3: self = .warning
        case 130, 143: self = .cancelled
        default: self = .failure
        }
    }
}

/// One JSON line that restic prints. Fields depend on `message_type`.
struct ResticMessage: Decodable {
    struct Inner: Decodable { var message: String? }
    var message_type: String?
    var message: String?
    var code: Int32?
    var error: Inner?
    var item: String?
    // status
    var percent_done: Double?
    var total_files: Int64?
    var files_done: Int64?
    var bytes_done: Int64?
    var current_files: [String]?
    // backup summary
    var snapshot_id: String?
    var data_added: Int64?
    var data_added_packed: Int64?
    var total_files_processed: Int64?
    var total_bytes_processed: Int64?
    var total_duration: Double?

    static func parse(_ line: String) -> ResticMessage? {
        guard line.first == "{", let data = line.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ResticMessage.self, from: data)
    }
}

/// Collects diagnostic messages from restic's output streams.
final class LogCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var warnings: [String] = []
    private var errors: [String] = []
    private var other: [String] = []

    func add(_ m: ResticMessage) {
        lock.lock(); defer { lock.unlock() }
        switch m.message_type {
        case "error":
            let text = m.error?.message ?? m.message ?? "Unknown problem"
            if warnings.count < 200, !warnings.contains(text) { warnings.append(text) }
        case "exit_error":
            if let msg = m.message { errors.append(msg) }
        default:
            break
        }
    }

    func addRaw(_ line: String) {
        guard !line.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        if other.count < 50 { other.append(line) }
    }

    var collectedWarnings: [String] { lock.lock(); defer { lock.unlock() }; return warnings }

    func error(exitCode: Int32) -> ResticError {
        lock.lock(); defer { lock.unlock() }
        let msgs = errors.isEmpty ? warnings : errors
        return ResticError(exitCode: exitCode, messages: msgs, rawMessages: other)
    }
}
