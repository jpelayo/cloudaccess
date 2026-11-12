// Apache 2 license - developer@infinitecontext.com

import Foundation
import Network
import Security
import Synchronization

/// Finds which part of reaching a server fails, one step at a time: this device's network,
/// Tailscale, the name, the route, the port and the service. It stops at the first step that
/// fails, so each later step is evidence only when every earlier one passed.
///
/// It only ever contacts the drive's own server, on the drive's own port, and reads this device's
/// own state. Nothing goes anywhere else. It runs after a real failure, never instead of trying.
public enum ConnectionCheck {
    /// One server, as drives on it share it.
    public struct Target: Hashable, Sendable {
        public var host: String
        public var port: Int
        public var isSFTP: Bool
        public var usesTLS: Bool

        public init(host: String, port: Int, isSFTP: Bool, usesTLS: Bool) {
            self.host = host
            self.port = port
            self.isSFTP = isSFTP
            self.usesTLS = usesTLS
        }

        public init?(_ connection: Connection) {
            switch connection.endpoint {
            case .webDAV(let url):
                guard let host = url.host, !host.isEmpty else { return nil }
                let isHTTPS = url.scheme?.lowercased() == "https"
                self.init(host: Self.unbracketed(host), port: url.port ?? (isHTTPS ? 443 : 80), isSFTP: false, usesTLS: isHTTPS)
            case .sftp(let host, let port):
                self.init(host: Self.unbracketed(host), port: port, isSFTP: true, usesTLS: false)
            case .localFolder:
                return nil
            }
        }

        private static func unbracketed(_ host: String) -> String {
            host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        }
    }

    /// How long each step waits for an answer.
    static let stepLimit: Duration = .seconds(10)

    /// Where a host's name or address says it is.
    public static func place(of host: String) -> ConnectionFacts.Place {
        let name = host.lowercased()
        if Tailnet.isTailscaleOnly(host: name) {
            return name.hasSuffix(".ts.net") || name.hasSuffix(".ts.net.") ? .tailscaleName : .tailscaleAddress
        }
        if Tailnet.contains(host: name) {
            return .sharedVPNAddress
        }
        if name.hasSuffix(".local") || name.hasSuffix(".local.") {
            return .localName
        }
        if isPrivate(name) {
            return .privateAddress
        }
        return .elsewhere
    }

    /// An address only a local network can reach: RFC 1918, link-local, and IPv6's local ranges.
    static func isPrivate(_ address: String) -> Bool {
        guard let bytes = IPRange.bytes(of: address) else { return false }
        if bytes.count == 4 {
            return bytes[0] == 10 || (bytes[0] == 172 && (16...31).contains(bytes[1]))
                || (bytes[0] == 192 && bytes[1] == 168) || (bytes[0] == 169 && bytes[1] == 254)
        }
        return (bytes[0] & 0xFE) == 0xFC || (bytes[0] == 0xFE && (bytes[1] & 0xC0) == 0x80)
    }

    /// This device's network now, read once from the system.
    public static func currentNetwork() async -> DeviceNetwork {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            let once = Once()
            monitor.pathUpdateHandler = { path in
                once.run {
                    continuation.resume(returning: DeviceNetwork.current(path: path))
                    monitor.cancel()
                }
            }
            monitor.start(queue: queue)
        }
    }

    /// Runs every step that's due.
    /// - Parameter asksTheService: Whether to read the server's first answer. An SSH server can
    ///   ban an address that keeps opening connections it never signs in on, so callers limit
    ///   how often this is asked.
    public static func run(_ target: Target, network: DeviceNetwork, asksTheService: Bool) async -> ConnectionFacts {
        var facts = ConnectionFacts(network: network, place: place(of: target.host))
        guard network.isUp else { return facts }
        let viaTailnet = [.tailscaleName, .tailscaleAddress, .sharedVPNAddress].contains(facts.place)
        if viaTailnet && !network.hasTailnetAddress {
            return facts
        }

        let (lookup, addresses) = await lookUp(target.host)
        facts.lookup = lookup
        guard let address = addresses.first else {
            // A .local name is answered on the local network, which a person may not have allowed.
            if facts.place == .localName,
               await knock(.name(target.host, nil), port: target.port, limit: .seconds(3)) == .localNetworkDenied {
                facts.port = .localNetworkDenied
            }
            return facts
        }
        facts.isOnOwnNetwork = network.isOnOwnNetwork(address)
        if facts.place == .elsewhere && isPrivate(address) {
            facts.place = .privateAddress
        }
        let route = self.route(toward: address, port: target.port, network: network)
        facts.route = route
        guard route != .unroutable else { return facts }

        let port = await knock(NWEndpoint.Host(address), port: target.port, limit: stepLimit)
        facts.port = port
        guard port == .open else { return facts }

        if !asksTheService {
            facts.answer = .notAsked
        } else if target.isSFTP {
            facts.answer = await sshAnswer(address: address, port: target.port)
        } else if target.usesTLS {
            let (answer, expiry) = await tlsAnswer(address: address, host: target.host, port: target.port)
            facts.answer = answer
            facts.certificateExpiry = expiry
        } else {
            facts.answer = .notAsked
        }
        return facts
    }

    // MARK: - Name

    private enum Resolved: Sendable {
        case addresses([String])
        case failed(Int32)
    }

    /// The host's addresses, in the order the system prefers them.
    static func lookUp(_ host: String) async -> (ConnectionFacts.Lookup, [String]) {
        if IPRange.bytes(of: host) != nil {
            return (.notNeeded, [host])
        }
        let resolved: Resolved
        do {
            resolved = try await withinTime(stepLimit) { await addresses(of: host) }
        } catch {
            return (.noAnswer, [])
        }
        switch resolved {
        case .addresses(let found) where !found.isEmpty:
            return (.found(found[0]), found)
        case .addresses:
            return (.notFound, [])
        case .failed(let status):
            // 7 is EAI_NODATA: the name exists, with no address.
            return (status == EAI_NONAME || status == 7 ? .notFound : .noAnswer, [])
        }
    }

    /// `getaddrinfo` blocks, so it runs on a queue of its own, never on Swift's threads.
    private static func addresses(of host: String) async -> Resolved {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var hints = addrinfo()
                hints.ai_socktype = SOCK_STREAM
                var first: UnsafeMutablePointer<addrinfo>?
                let status = getaddrinfo(host, nil, &hints, &first)
                guard status == 0, let first else {
                    continuation.resume(returning: .failed(status))
                    return
                }
                defer { freeaddrinfo(first) }
                var found: [String] = []
                for entry in sequence(first: first, next: { $0.pointee.ai_next }) {
                    if let address = entry.pointee.ai_addr, let text = DeviceNetwork.numericHost(address), !found.contains(text) {
                        found.append(text)
                    }
                }
                continuation.resume(returning: .addresses(found))
            }
        }
    }

    // MARK: - Route

    /// Which way traffic for an address would leave. Connecting a UDP socket only asks the system
    /// for a route: nothing is sent.
    static func route(toward address: String, port: Int, network: DeviceNetwork) -> ConnectionFacts.Route {
        guard let local = sourceAddress(toward: address, port: port) else { return .unroutable }
        if let interface = network.interface(holding: local), interface.isTunnel {
            return Tailnet.contains(host: local) ? .tailnet : .otherTunnel
        }
        return network.isOnOwnNetwork(address) ? .ownNetwork : .router
    }

    private static func sourceAddress(toward address: String, port: Int) -> String? {
        var hints = addrinfo()
        hints.ai_flags = AI_NUMERICHOST
        hints.ai_socktype = SOCK_DGRAM
        var first: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(address, String(port), &hints, &first) == 0, let first else { return nil }
        defer { freeaddrinfo(first) }
        let entry = first.pointee
        let socket = Darwin.socket(entry.ai_family, SOCK_DGRAM, IPPROTO_UDP)
        guard socket >= 0 else { return nil }
        defer { close(socket) }
        guard connect(socket, entry.ai_addr, entry.ai_addrlen) == 0 else { return nil }
        var local = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let named = withUnsafeMutablePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socket, $0, &length) }
        }
        guard named == 0 else { return nil }
        return withUnsafePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { DeviceNetwork.numericHost($0) }
        }
    }

    // MARK: - Port

    /// Opens a TCP connection and closes it, saying how far it got.
    static func knock(_ host: NWEndpoint.Host, port: Int, limit: Duration) async -> ConnectionFacts.Port {
        guard let number = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return .noRoute }
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = Int(limit.components.seconds)
        let connection = NWConnection(host: host, port: number, using: NWParameters(tls: nil, tcp: tcp))
        let result = await finish(connection, limit: limit) { state in
            switch state {
            case .ready:
                return .open
            case .waiting(let error), .failed(let error):
                if connection.currentPath?.unsatisfiedReason == .localNetworkDenied {
                    return .localNetworkDenied
                }
                return portResult(for: error)
            default:
                return nil
            }
        }
        connection.cancel()
        return result ?? .timedOut
    }

    static func portResult(for error: NWError) -> ConnectionFacts.Port {
        guard case .posix(let code) = error else { return .timedOut }
        switch code {
        case .ECONNREFUSED, .ECONNRESET: return .refused
        case .EHOSTDOWN, .EHOSTUNREACH: return .hostDown
        case .ENETUNREACH, .EADDRNOTAVAIL, .ENETDOWN: return .noRoute
        default: return .timedOut
        }
    }

    // MARK: - Service

    /// The first thing an SSH server says is its version, starting `SSH-`.
    /// - Parameter limit: In whole seconds.
    static func sshAnswer(address: String, port: Int, limit: Duration = stepLimit) async -> ConnectionFacts.Answer {
        guard let number = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return .closed }
        let connection = NWConnection(host: NWEndpoint.Host(address), port: number, using: .tcp)
        defer { connection.cancel() }
        let ready = await finish(connection, limit: limit) { state -> Bool? in
            switch state {
            case .ready: true
            case .waiting, .failed: false
            default: nil
            }
        }
        guard ready == true else { return .closed }
        let once = Once()
        return await withCheckedContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 255) { data, _, isComplete, error in
                once.run {
                    if let data, !data.isEmpty {
                        continuation.resume(returning: data.starts(with: Array("SSH-".utf8)) ? .ssh : .notSSH)
                    } else {
                        continuation.resume(returning: isComplete || error != nil ? .closed : .silent)
                    }
                }
            }
            queue.asyncAfter(deadline: .now() + .seconds(Int(limit.components.seconds))) {
                once.run { continuation.resume(returning: .silent) }
            }
        }
    }

    /// A TLS handshake with the drive's own host name, and the system's verdict on its
    /// certificate. The connection carries on whatever the verdict, only to see it through.
    /// - Returns: The answer, and for an expired certificate, the date it expired on.
    /// - Parameter limit: In whole seconds.
    static func tlsAnswer(
        address: String, host: String, port: Int, limit: Duration = stepLimit
    ) async -> (ConnectionFacts.Answer, Date?) {
        guard let number = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return (.closed, nil) }
        let verdict = Verdict()
        let tls = NWProtocolTLS.Options()
        let security = tls.securityProtocolOptions
        if IPRange.bytes(of: host) == nil {
            sec_protocol_options_set_tls_server_name(security, host)
        }
        sec_protocol_options_set_verify_block(security, { _, trust, complete in
            let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
            SecTrustSetPolicies(secTrust, SecPolicyCreateSSL(true, host as CFString))
            var error: CFError?
            if SecTrustEvaluateWithError(secTrust, &error) {
                verdict.set(.tls)
            } else {
                let code = error.map { CFErrorGetCode($0) } ?? 0
                let answer = certificateAnswer(for: OSStatus(code))
                // The server's own certificate comes first in the chain. Its date is said only if
                // it's the one that expired, not one further up the chain.
                let own = (SecTrustCopyCertificateChain(secTrust) as? [SecCertificate])?.first
                let ends = own.flatMap { SecCertificateCopyNotValidAfterDate($0) }.map { $0 as Date }
                verdict.set(answer, expired: answer == .certificateExpired ? ends.flatMap { $0 < Date() ? $0 : nil } : nil)
            }
            complete(true)
        }, queue)
        let connection = NWConnection(
            host: NWEndpoint.Host(address), port: number, using: NWParameters(tls: tls, tcp: NWProtocolTCP.Options()))
        defer { connection.cancel() }
        let answer = await finish(connection, limit: limit) { state -> ConnectionFacts.Answer? in
            switch state {
            case .ready:
                return verdict.value ?? .tls
            case .waiting(let error), .failed(let error):
                if case .tls = error {
                    return verdict.value ?? .notTLS
                }
                return .closed
            default:
                return nil
            }
        }
        return (answer ?? .silent, answer == .certificateExpired ? verdict.expired : nil)
    }

    static func certificateAnswer(for status: OSStatus) -> ConnectionFacts.Answer {
        switch status {
        case errSecCertificateExpired: .certificateExpired
        case errSecHostNameMismatch: .certificateWrongName
        default: .certificateUntrusted
        }
    }

    // MARK: - Waiting

    static let queue = DispatchQueue(label: "cloudaccess.connection-check")

    /// Starts a connection and gives the first result `decide` makes of its states, or nil if the
    /// time runs out first.
    private static func finish<Value: Sendable>(
        _ connection: NWConnection, limit: Duration, decide: @escaping @Sendable (NWConnection.State) -> Value?
    ) async -> Value? {
        let once = Once()
        return await withCheckedContinuation { continuation in
            connection.stateUpdateHandler = { state in
                if let value = decide(state) {
                    once.run { continuation.resume(returning: value) }
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + .milliseconds(Int(limit.components.seconds * 1000) + 500)) {
                once.run { continuation.resume(returning: nil) }
            }
        }
    }
}

/// Runs its work the first time only, whichever caller gets there first.
private final class Once: Sendable {
    private let done = Mutex(false)

    func run(_ work: () -> Void) {
        let first = done.withLock { done in
            defer { done = true }
            return !done
        }
        if first {
            work()
        }
    }
}

/// The certificate's verdict, set on the connection's queue and read after it's ready.
private final class Verdict: Sendable {
    private let answer = Mutex<ConnectionFacts.Answer?>(nil)
    private let expiry = Mutex<Date?>(nil)

    var value: ConnectionFacts.Answer? {
        answer.withLock { $0 }
    }

    /// When the server's own certificate stopped being valid, for one that expired.
    var expired: Date? {
        expiry.withLock { $0 }
    }

    func set(_ new: ConnectionFacts.Answer, expired date: Date? = nil) {
        answer.withLock { $0 = new }
        expiry.withLock { $0 = date }
    }
}
