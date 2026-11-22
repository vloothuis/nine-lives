import Foundation
import Network

/// Quick check whether a server accepts connections, for example to tell if the laptop is on the server's LAN.
public enum ServerReachability {
    public static func isReachable(host: String, port: Int, timeout: TimeInterval = 4) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return false }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        let gate = Gate()
        return await withCheckedContinuation { cont in
            @Sendable func finish(_ ok: Bool) {
                guard gate.claim() else { return }
                connection.cancel()
                cont.resume(returning: ok)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true)
                case .failed, .cancelled: finish(false)
                case .waiting: finish(false) // no route or host unreachable
                default: break
                }
            }
            connection.start(queue: DispatchQueue(label: "org.ninelives.reachability"))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(false) }
        }
    }

    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var used = false
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if used { return false }
            used = true
            return true
        }
    }
}
