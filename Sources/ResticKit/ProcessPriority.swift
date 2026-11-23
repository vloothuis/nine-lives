import Darwin
import Foundation

/// Tells macOS how urgent the processes of one job are.
///
/// In background mode macOS gives the processes less CPU time, throttles their
/// disk reads and writes, and sends their network traffic at low priority. Child
/// processes, such as the ssh connection restic opens, inherit the mode.
///
/// `ProcessRunner` applies the priority in `current` to every process it starts.
/// `raise()` lifts background mode, also on processes that are already running.
public final class ProcessPriority: @unchecked Sendable {
    @TaskLocal public static var current: ProcessPriority?

    private let lock = NSLock()
    private var background: Bool
    private var pids: Set<pid_t> = []

    public init(background: Bool) {
        self.background = background
    }

    public var isBackground: Bool {
        lock.lock(); defer { lock.unlock() }
        return background
    }

    /// Ends background mode for running and future processes of this job.
    public func raise() {
        lock.lock(); defer { lock.unlock() }
        guard background else { return }
        background = false
        for pid in pids { Self.setBackground(false, tree: pid) }
    }

    func attach(_ pid: pid_t) {
        lock.lock(); defer { lock.unlock() }
        pids.insert(pid)
        // Set on the process itself, not at spawn time, so that raise() can undo it.
        if background { setpriority(PRIO_DARWIN_PROCESS, id_t(pid), PRIO_DARWIN_BG) }
    }

    func detach(_ pid: pid_t) {
        lock.lock(); defer { lock.unlock() }
        pids.remove(pid)
    }

    /// Sets the mode on a process and all its descendants. Children inherit the
    /// mode when they start, but clearing it on the parent does not reach them.
    private static func setBackground(_ on: Bool, tree pid: pid_t) {
        for child in ProcessTree.children(of: pid) { setBackground(on, tree: child) }
        setpriority(PRIO_DARWIN_PROCESS, id_t(pid), on ? PRIO_DARWIN_BG : 0)
    }
}
