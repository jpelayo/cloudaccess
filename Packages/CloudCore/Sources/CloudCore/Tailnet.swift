// Apache 2 license - developer@infinitecontext.com

import Foundation

/// Servers reached through Tailscale. With Tailscale off, one looks exactly like a server that's
/// down, so the apps say what to check. No app can turn on another app's VPN, so they can't do more.
public enum Tailnet {
    public static let hint = "This server is on a tailnet. Check that Tailscale is on."

    /// Tailscale's names end in ts.net, and its addresses are in 100.64.0.0/10 and
    /// fd7a:115c:a1e0::/48. Other networks use that IPv4 range too, which is why the hint says to
    /// check, rather than saying Tailscale is off.
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

    /// A failed connection in words, with what to check when that's worth saying. A wrong password
    /// reached the server, so that's never Tailscale's doing.
    public static func explain(_ error: Error, for endpoint: Connection.Endpoint) -> String {
        guard contains(endpoint), case RemoteError.unreachable = error else {
            return error.localizedDescription
        }
        return "\(error.localizedDescription) \(hint)"
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
