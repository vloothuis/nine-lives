import Foundation
import Network
import ResticKit

/// Quick check whether a server accepts connections, for example to tell if the laptop is on the server's LAN.
public enum ServerReachability {
    /// Where ssh will connect for a server, after applying the user's ssh config.
    public struct Target: Equatable, Sendable {
        public var host: String
        public var port: Int
        /// True when ssh goes through a proxy or jump host, so a direct connection says nothing.
        public var viaProxy: Bool
    }

    /// Checks the server the way ssh would reach it, so host aliases from `~/.ssh/config` work.
    public static func isReachable(_ server: RemoteServer, timeout: TimeInterval = 4) async -> Bool {
        await probe(server, timeout: timeout).reachable
    }

    /// `direct` is false when ssh goes through a proxy: then `reachable` is always true and says nothing.
    public static func probe(_ server: RemoteServer, timeout: TimeInterval = 4) async -> (reachable: Bool, direct: Bool) {
        let target = await resolve(server)
        if target.viaProxy { return (true, false) }
        return (await isReachable(host: target.host, port: target.port, timeout: timeout), true)
    }

    /// Asks ssh for its effective settings. Falls back to the stored host and port when that fails.
    public static func resolve(_ server: RemoteServer) async -> Target {
        let fallback = Target(host: server.host, port: server.port, viaProxy: false)
        let result = try? await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/ssh"),
            arguments: ["-G", "-p", String(server.port), "\(server.user)@\(server.host)"],
            environment: ProcessInfo.processInfo.environment)
        guard let result, result.exitCode == 0 else { return fallback }
        return parse(sshConfig: String(decoding: result.stdout, as: UTF8.self), fallback: fallback)
    }

    /// Reads `hostname`, `port`, `proxyjump` and `proxycommand` from `ssh -G` output.
    public static func parse(sshConfig: String, fallback: Target) -> Target {
        var target = fallback
        for line in sshConfig.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            switch parts[0].lowercased() {
            case "hostname": target.host = parts[1]
            case "port": target.port = Int(parts[1]) ?? target.port
            case "proxyjump", "proxycommand": if parts[1].lowercased() != "none" { target.viaProxy = true }
            default: break
            }
        }
        return target
    }

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
