import Foundation

public struct BorgError: LocalizedError, Sendable {
    public var exitCode: Int32
    public var msgid: String?
    public var messages: [String]
    /// Unstructured output, for example errors printed by ssh.
    public var rawMessages: [String]

    public init(exitCode: Int32, msgid: String? = nil, messages: [String] = [], rawMessages: [String] = []) {
        self.exitCode = exitCode
        self.msgid = msgid
        self.messages = messages
        self.rawMessages = rawMessages
    }

    private var everything: [String] { messages + rawMessages }

    /// The server rejected our key or the user does not exist.
    public var isAuthenticationFailure: Bool {
        everything.contains { $0.localizedCaseInsensitiveContains("permission denied") }
    }

    /// The server could not be reached at all.
    public var isConnectionProblem: Bool {
        if isAuthenticationFailure { return true }
        let id = msgid ?? ""
        if id.contains("ConnectionClosed") { return true }
        let needles = ["could not resolve", "connection refused", "connection timed out", "operation timed out",
                       "no route to host", "network is unreachable", "connection closed", "connection reset",
                       "broken pipe", "host key verification failed", "name or service not known", "nodename nor servname"]
        return everything.contains { line in needles.contains { line.localizedCaseInsensitiveContains($0) } }
    }

    /// ssh worked but there is no usable borg on the server.
    public var isBorgMissingOnServer: Bool {
        everything.contains { $0.localizedCaseInsensitiveContains("command not found")
            || $0.localizedCaseInsensitiveContains("borg: not found") }
    }

    /// A short sentence for people. Technical output is in `details`.
    public var errorDescription: String? { summary }

    public var summary: String {
        if isWrongPassphrase { return "The saved passphrase does not match." }
        if isOutOfSpace { return "The backup location is full." }
        if isAuthenticationFailure { return "The server did not accept the Nine Lives key." }
        if isBorgMissingOnServer { return "borg is not available on the server." }
        if isConnectionProblem { return "Could not reach the server." }
        if everything.contains(where: { $0.hasPrefix("Borg server:") || $0.contains("Traceback") }) {
            return "The server's borg could not complete the request. It may be an older version than the one on this Mac."
        }
        let lines = everything.filter { !$0.isEmpty }
        if lines.count == 1, let one = lines.first, one.count <= 160 { return one }
        return "borg reported an error (code \(exitCode))."
    }

    /// The full technical output, for the Details view and for copying.
    public var details: String? {
        let text = everything.filter { !$0.isEmpty }.joined(separator: "\n")
        return text.isEmpty || text == summary ? nil : text
    }

    public var isCancelled: Bool { exitCode == 130 || exitCode == 143 || exitCode == 128 + 2 }

    public var isWrongPassphrase: Bool {
        (msgid?.contains("Passphrase") ?? false)
            || messages.contains { $0.localizedCaseInsensitiveContains("passphrase") }
    }

    public var isLockProblem: Bool {
        let id = msgid ?? ""
        return id.contains("Lock") || messages.contains { $0.contains("lock") && $0.contains("acquire") }
    }

    public var isRepositoryMissing: Bool {
        (msgid ?? "").contains("DoesNotExist") || (msgid ?? "").contains("InvalidRepository")
    }

    public var isOutOfSpace: Bool {
        let id = msgid ?? ""
        return id.contains("InsufficientFreeSpace")
            || messages.contains { $0.localizedCaseInsensitiveContains("no space left") }
    }
}

/// Classification of borg's modern exit codes.
public enum BorgExit: Equatable, Sendable {
    case success
    case warning
    case failure
    case cancelled

    public init(code: Int32) {
        switch code {
        case 0: self = .success
        case 1, 100...127: self = .warning
        case 130, 143: self = .cancelled
        default: self = .failure
        }
    }
}

/// One line of borg's `--log-json` stderr stream.
struct BorgLogLine: Decodable {
    var type: String
    var message: String?
    var levelname: String?
    var msgid: String?
    var original_size: Int64?
    var compressed_size: Int64?
    var deduplicated_size: Int64?
    var nfiles: Int64?
    var path: String?
    var finished: Bool?

    static func parse(_ line: String) -> BorgLogLine? {
        guard line.first == "{", let data = line.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(BorgLogLine.self, from: data)
    }
}

/// Collects diagnostic messages from the stderr stream.
final class LogCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var warnings: [String] = []
    private var errors: [String] = []
    private var lastMsgid: String?
    private var other: [String] = []

    func add(_ line: BorgLogLine) {
        guard line.type == "log_message", let message = line.message else { return }
        lock.lock(); defer { lock.unlock() }
        switch line.levelname?.uppercased() {
        case "WARNING":
            warnings.append(message)
        case "ERROR", "CRITICAL":
            errors.append(message)
            if let id = line.msgid { lastMsgid = id }
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

    func error(exitCode: Int32) -> BorgError {
        lock.lock(); defer { lock.unlock() }
        let msgs = errors.isEmpty ? (warnings + other) : errors
        return BorgError(exitCode: exitCode, msgid: lastMsgid, messages: msgs, rawMessages: other)
    }
}
