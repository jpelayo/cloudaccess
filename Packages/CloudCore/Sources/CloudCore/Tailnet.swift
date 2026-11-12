// Apache 2 license - developer@infinitecontext.com

import Foundation

/// Servers reached through Tailscale. Whether Tailscale is off is never guessed from the address:
/// `ConnectionCheck` looks for this device's own tailnet address, so a server that's off with
/// Tailscale on is called off, not blamed on Tailscale.
public enum Tailnet {
    /// Tailscale's names end in ts.net, and its addresses are in 100.64.0.0/10 and
    /// fd7a:115c:a1e0::/48. Other networks use that IPv4 range too.
    public static func contains(host: String) -> Bool {
        var name = host.lowercased()
        if name.hasSuffix(".") {
            name.removeLast()
        }
        if name.hasSuffix(".ts.net") || name.hasPrefix("fd7a:115c:a1e0:") {
            return true
        }
        let parts = name.split(separator: ".", omittingEmptySubsequences: false).map { UInt8($0) }
        guard parts.count == 4, !parts.contains(nil), let first = parts[0], let second = parts[1] else {
            return false
        }
        return first == 100 && (64...127).contains(second)
    }

    public static func contains(_ endpoint: Connection.Endpoint) -> Bool {
        endpoint.host.map { contains(host: $0) } ?? false
    }

    /// A name or address that only Tailscale uses. 100.64.0.0/10 isn't one: other VPNs use it.
    public static func isTailscaleOnly(host: String) -> Bool {
        var name = host.lowercased()
        if name.hasSuffix(".") {
            name.removeLast()
        }
        return name.hasSuffix(".ts.net") || name.hasPrefix("fd7a:115c:a1e0:")
    }

}

extension Connection.Endpoint {
    public var host: String? {
        switch self {
        case .webDAV(let url): url.host
        case .sftp(let host, _): host
        case .localFolder: nil
        }
    }
}

extension Connection {
    public var usesTailnet: Bool {
        Tailnet.contains(endpoint)
    }
}
