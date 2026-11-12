// Apache 2 license - developer@infinitecontext.com

import Foundation
import Network

/// What this device's own network looks like at one moment: whether it's up, why not, and which
/// addresses it has on which interfaces. It only knows this device. A server can still be down
/// with all of this fine.
public struct DeviceNetwork: Equatable, Sendable {
    /// Why the system says there's no usable network.
    public enum Unsatisfied: String, Equatable, Sendable {
        /// No interface is connected.
        case notAvailable
        /// A person turned off mobile data for this app.
        case cellularDenied
        /// A person turned off Wi-Fi for this app.
        case wifiDenied
        /// A person turned off local network access for this app.
        case localNetworkDenied
        case other
    }

    /// One address on one interface.
    public struct Interface: Equatable, Sendable {
        public var name: String
        public var address: String
        /// How many leading bits are the network's, from the interface's netmask.
        public var prefixLength: Int

        public init(name: String, address: String, prefixLength: Int) {
            self.name = name
            self.address = address
            self.prefixLength = prefixLength
        }

        /// A VPN's interface. Wi-Fi, Ethernet and mobile data are never one.
        public var isTunnel: Bool {
            ["utun", "ipsec", "ppp", "tun", "tap"].contains { name.hasPrefix($0) }
        }
    }

    public var isUp: Bool
    public var unsatisfied: Unsatisfied?
    public var interfaces: [Interface]

    public init(isUp: Bool, unsatisfied: Unsatisfied? = nil, interfaces: [Interface] = []) {
        self.isUp = isUp
        self.unsatisfied = unsatisfied
        self.interfaces = interfaces
    }

    /// Whether Tailscale, or a VPN like it, has given this device an address. Mobile carriers hand
    /// out addresses in Tailscale's IPv4 range too, so only a tunnel's count.
    public var hasTailnetAddress: Bool {
        interfaces.contains { $0.isTunnel && Tailnet.contains(host: $0.address) }
    }

    /// The interface that holds this address, if this device has it.
    public func interface(holding address: String) -> Interface? {
        interfaces.first { $0.address == address }
    }

    /// Whether an address is on one of this device's own networks, so nothing but that network
    /// stands between them. Tunnels don't count: their networks are elsewhere.
    public func isOnOwnNetwork(_ address: String) -> Bool {
        interfaces.contains { !$0.isTunnel && IPRange(address: $0.address, prefixLength: $0.prefixLength)?.contains(address) == true }
    }

    /// The device's network now, from the system.
    public static func current(path: NWPath) -> DeviceNetwork {
        DeviceNetwork(
            isUp: path.status == .satisfied,
            unsatisfied: path.status == .satisfied ? nil : Unsatisfied(path.unsatisfiedReason),
            interfaces: addresses())
    }

    /// Every address this device has, by interface, with loopback left out.
    public static func addresses() -> [Interface] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let first else { return [] }
        defer { freeifaddrs(first) }
        var found: [Interface] = []
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let item = entry.pointee
            guard let address = item.ifa_addr, (item.ifa_flags & UInt32(IFF_UP)) != 0,
                  (item.ifa_flags & UInt32(IFF_LOOPBACK)) == 0,
                  let text = numericHost(address)
            else { continue }
            let prefix = item.ifa_netmask.map(prefixLength(of:)) ?? 0
            found.append(Interface(name: String(cString: item.ifa_name), address: text, prefixLength: prefix))
        }
        return found
    }

    /// An IPv4 or IPv6 address as text, without a zone. Nil for any other kind.
    static func numericHost(_ address: UnsafePointer<sockaddr>) -> String? {
        let family = Int32(address.pointee.sa_family)
        guard family == AF_INET || family == AF_INET6 else { return nil }
        let length = socklen_t(family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(address, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
        let text = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return text.split(separator: "%").first.map(String.init)
    }

    private static func prefixLength(of mask: UnsafeMutablePointer<sockaddr>) -> Int {
        let family = Int32(mask.pointee.sa_family)
        var bytes: [UInt8] = []
        if family == AF_INET {
            mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                withUnsafeBytes(of: $0.pointee.sin_addr) { bytes = Array($0) }
            }
        } else if family == AF_INET6 {
            mask.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                withUnsafeBytes(of: $0.pointee.sin6_addr) { bytes = Array($0) }
            }
        }
        return bytes.reduce(0) { $0 + $1.nonzeroBitCount }
    }
}

extension DeviceNetwork.Unsatisfied {
    init(_ reason: NWPath.UnsatisfiedReason) {
        switch reason {
        case .notAvailable: self = .notAvailable
        case .cellularDenied: self = .cellularDenied
        case .wifiDenied: self = .wifiDenied
        case .localNetworkDenied: self = .localNetworkDenied
        default: self = .other
        }
    }
}

/// A network's addresses, from one address and its prefix length.
struct IPRange {
    private let network: [UInt8]
    private let prefixLength: Int

    init?(address: String, prefixLength: Int) {
        guard let bytes = IPRange.bytes(of: address), prefixLength > 0 else { return nil }
        network = bytes
        self.prefixLength = min(prefixLength, bytes.count * 8)
    }

    func contains(_ address: String) -> Bool {
        guard let other = IPRange.bytes(of: address), other.count == network.count else { return false }
        var bits = prefixLength
        for (mine, theirs) in zip(network, other) where bits > 0 {
            let mask: UInt8 = bits >= 8 ? 0xFF : ~(0xFF >> UInt8(bits))
            if mine & mask != theirs & mask {
                return false
            }
            bits -= 8
        }
        return true
    }

    /// The address's bytes: 4 for IPv4, 16 for IPv6. Nil for a name.
    static func bytes(of address: String) -> [UInt8]? {
        if let four = IPv4Address(address) {
            return Array(four.rawValue)
        }
        if let six = IPv6Address(address) {
            return Array(six.rawValue)
        }
        return nil
    }
}
