import Foundation

/// Splits a byte stream into UTF-8 lines. Thread safe.
final class LineSplitter: @unchecked Sendable {
    private var buffer = Data()
    private let lock = NSLock()
    private let handler: @Sendable (String) -> Void

    init(_ handler: @escaping @Sendable (String) -> Void) {
        self.handler = handler
    }

    func feed(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(data)
        var start = buffer.startIndex
        while let idx = buffer[start...].firstIndex(of: 0x0A) {
            handler(String(decoding: buffer[start..<idx], as: UTF8.self))
            start = idx + 1
        }
        if start != buffer.startIndex {
            buffer = Data(buffer[start...])
        }
    }

    func finish() {
        lock.lock()
        defer { lock.unlock() }
        if !buffer.isEmpty {
            handler(String(decoding: buffer, as: UTF8.self))
            buffer.removeAll()
        }
    }
}

final class LockedData: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()
    func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
    var value: Data { lock.lock(); defer { lock.unlock() }; return data }
}

final class LockedLines: @unchecked Sendable {
    private var lines: [String] = []
    private let lock = NSLock()
    func add(_ l: String) { lock.lock(); lines.append(l); lock.unlock() }
    var all: String { lock.lock(); defer { lock.unlock() }; return lines.joined(separator: "\n") }
}

public struct ProcessResult: Sendable {
    public let exitCode: Int32
    public let stdout: Data
}

enum ProcessTree {
    static func children(of pid: pid_t) -> [pid_t] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-P", String(pid)]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { pid_t($0) }
    }

    /// Signals a process and all its descendants, children first.
    static func signal(_ pid: pid_t, _ sig: Int32) {
        for child in children(of: pid) { signal(child, sig) }
        kill(pid, sig)
    }

    static func isAlive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }
}

public enum ProcessRunner {
    /// Runs a process, streaming stderr (and optionally stdout) line by line.
    /// Cancelling the task sends SIGINT, then SIGTERM after a grace period.
    /// The process runs with the priority in `ProcessPriority.current`, if any.
    /// With `signalTree` false, only the process itself is signalled, so it can still use its children
    /// (for example ssh) to clean up.
    public static func run(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        currentDirectory: URL? = nil,
        signalTree: Bool = true,
        onStdoutLine: (@Sendable (String) -> Void)? = nil,
        onStderrLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = currentDirectory
        process.qualityOfService = .utility

        let outPipe = Pipe()
        let errPipe = Pipe()
        let nullIn = FileHandle.nullDevice
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = nullIn

        let collected = LockedData()
        let outSplitter = onStdoutLine.map { LineSplitter($0) }
        let errSplitter = onStderrLine.map { LineSplitter($0) }

        let group = DispatchGroup()
        group.enter()
        group.enter()
        group.enter()

        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let d = handle.availableData
            if d.isEmpty {
                handle.readabilityHandler = nil
                outSplitter?.finish()
                group.leave()
            } else if let outSplitter {
                outSplitter.feed(d)
            } else {
                collected.append(d)
            }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let d = handle.availableData
            if d.isEmpty {
                handle.readabilityHandler = nil
                errSplitter?.finish()
                group.leave()
            } else {
                errSplitter?.feed(d)
            }
        }
        let priority = ProcessPriority.current
        process.terminationHandler = { _ in group.leave() }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ProcessResult, Error>) in
                do {
                    try process.run()
                } catch {
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    cont.resume(throwing: error)
                    return
                }
                priority?.attach(process.processIdentifier)
                if Task.isCancelled { process.interrupt() }
                group.notify(queue: .global()) {
                    // Runs after attach, so a quick exit cannot leave a stale pid behind.
                    priority?.detach(process.processIdentifier)
                    cont.resume(returning: ProcessResult(
                        exitCode: process.terminationStatus,
                        stdout: collected.value
                    ))
                }
            }
        } onCancel: {
            guard process.isRunning else { return }
            let pid = process.processIdentifier
            // Signal the whole tree, so child processes such as ssh stop too.
            let send: @Sendable (Int32) -> Void = { sig in
                if signalTree { ProcessTree.signal(pid, sig) } else { kill(pid, sig) }
            }
            send(SIGINT)
            DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
                if process.isRunning { send(SIGTERM) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 20) {
                // Children are killed too here, so a hung ssh cannot outlive the engine.
                if process.isRunning { ProcessTree.signal(pid, SIGKILL) }
            }
        }
    }
}
