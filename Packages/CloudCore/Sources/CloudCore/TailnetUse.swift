// Apache 2 license - developer@infinitecontext.com

import Foundation

/// Which drives this device has reached through Tailscale, and when. A drive's address doesn't
/// always say it needs Tailscale: a MagicDNS short name, a custom name, or a LAN address behind a
/// subnet route look like anything else. Having reached it that way is the proof, so with
/// Tailscale off its failure can be put down to Tailscale.
public struct TailnetUse: Codable, Equatable, Sendable {
    /// How long having used Tailscale counts. A server that moved off the tailnet stops being
    /// blamed on it after this.
    public static let remembered: TimeInterval = 90 * 24 * 60 * 60

    /// When each drive was last reached through Tailscale.
    private var lastSeen: [UUID: Date] = [:]
    /// The Tailscale name of each drive saved by its Tailscale address, read while it worked. A
    /// tailnet hands out a new address when a device is added again, and its name finds it.
    private var names: [UUID: String] = [:]

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case lastSeen
        case names
    }

    /// Records kept before names were don't have them.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lastSeen = try container.decode([UUID: Date].self, forKey: .lastSeen)
        names = try container.decodeIfPresent([UUID: String].self, forKey: .names) ?? [:]
    }

    /// Keeps a Tailscale name for the drive. Only a MagicDNS name counts: any other name an
    /// address answers to isn't Tailscale's, and can't find it again.
    public mutating func noteName(_ name: String, of drive: UUID) {
        let bare = name.hasSuffix(".") ? String(name.dropLast()) : name
        guard Tailnet.isTailscaleOnly(host: bare.lowercased()) else { return }
        names[drive] = bare
    }

    public func name(of drive: UUID) -> String? {
        names[drive]
    }

    /// The server's new Tailscale address, when the drive was saved by its old one and its name
    /// now gives another. Nil for anything else: a drive saved by name follows by itself.
    /// - Parameter found: What the name gives now.
    public static func movedAddress(saved: String, name: String?, found: [String]) -> String? {
        guard name != nil, IPRange.bytes(of: saved) != nil, Tailnet.contains(host: saved) else { return nil }
        return found.first { Tailnet.contains(host: $0) && $0 != saved }
    }

    /// Records how a drive was just reached. A direct route never erases Tailscale: the same drive
    /// can be reached directly at home and through Tailscale away.
    public mutating func note(_ drive: UUID, throughTailnet: Bool, at date: Date) {
        if throughTailnet {
            lastSeen[drive] = date
        }
    }

    public func usesTailnet(_ drive: UUID, at date: Date) -> Bool {
        guard let seen = lastSeen[drive] else { return false }
        return date.timeIntervalSince(seen) < Self.remembered
    }

    /// Drops drives that are gone.
    public mutating func keep(only drives: Set<UUID>) {
        lastSeen = lastSeen.filter { drives.contains($0.key) }
        names = names.filter { drives.contains($0.key) }
    }

    /// Whether traffic to this address goes through Tailscale: the address is Tailscale's, or the
    /// route leaves through a tunnel holding a tailnet address, as a subnet route does.
    public static func isThroughTailnet(address: String, route: ConnectionFacts.Route?) -> Bool {
        Tailnet.contains(host: address) || route == .tailnet
    }
}

/// Whether this device's tailnet address came or went since the last look. macOS doesn't always
/// report a tunnel coming up as a change of network, and drives waiting on Tailscale should
/// reconnect as soon as it's back.
public struct TailnetPresence: Sendable {
    private var last: Bool?

    public init() {}

    /// Takes in what's seen now, and says whether it changed. The first look is never a change.
    public mutating func changed(to now: Bool) -> Bool {
        defer { last = now }
        return last.map { $0 != now } ?? false
    }
}

extension ConnectionCheck {
    /// The name an address answers to, from the system's resolver, which on a tailnet is
    /// Tailscale's own. Nothing else is asked.
    public static func name(of address: String) async -> String? {
        await withCheckedContinuation { continuation in
            // getnameinfo blocks, so it runs on a queue of its own, never on Swift's threads.
            DispatchQueue.global(qos: .utility).async {
                var hints = addrinfo()
                hints.ai_flags = AI_NUMERICHOST
                var first: UnsafeMutablePointer<addrinfo>?
                guard getaddrinfo(address, nil, &hints, &first) == 0, let first else {
                    continuation.resume(returning: nil)
                    return
                }
                defer { freeaddrinfo(first) }
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let status = getnameinfo(
                    first.pointee.ai_addr, first.pointee.ai_addrlen, &host, socklen_t(host.count), nil, 0, NI_NAMEREQD)
                guard status == 0 else {
                    continuation.resume(returning: nil)
                    return
                }
                let bytes = host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                continuation.resume(returning: String(decoding: bytes, as: UTF8.self))
            }
        }
    }

    /// What a name gives now, from the system's resolver.
    public static func currentAddresses(of name: String) async -> [String] {
        await lookUp(name).1
    }

    /// Whether this server is reached through Tailscale now. It asks only the system's resolver,
    /// which already knows the name from connecting, and the system's routes: nothing is sent.
    public static func isReachedThroughTailnet(_ target: Target, network: DeviceNetwork) async -> Bool {
        if [.tailscaleName, .tailscaleAddress].contains(place(of: target.host)) {
            return true
        }
        let (_, addresses) = await lookUp(target.host)
        guard let address = addresses.first else { return false }
        let way = route(toward: address, port: target.port, network: network)
        return TailnetUse.isThroughTailnet(address: address, route: way)
    }
}
