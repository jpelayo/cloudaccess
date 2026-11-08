// Apache 2 license - developer@infinitecontext.com

import Foundation

/// Plain descriptions of a drive, safe to show and to include in diagnostics.
public enum ConnectionSummary {
    /// An address a person can read. Connections never hold secrets, so this can't leak one.
    public static func address(of connection: Connection) -> String {
        switch connection.endpoint {
        case .webDAV(let url):
            return url.absoluteString
        case .sftp(let host, let port):
            return "sftp://\(host):\(port)\(connection.rootPath)"
        case .localFolder:
            return connection.rootPath
        }
    }

    /// A diagnostics line. It says what kind of drive this is, not where it is.
    public static func line(for connection: Connection, status: String?) -> String {
        var parts = traits(of: connection)
        if let status { parts.append(status) }
        return "Drive: " + parts.joined(separator: ", ")
    }

    /// One fact about a drive.
    public struct Detail: Hashable, Sendable {
        public var key: String
        public var value: String

        public init(key: String, value: String) {
            self.key = key
            self.value = value
        }
    }

    /// What the side panel says about a drive: where it is and what kind it is.
    public static func details(of connection: Connection) -> [Detail] {
        var details = [Detail(key: "Address", value: address(of: connection))]
        if !connection.username.isEmpty {
            details.append(Detail(key: "User", value: connection.username))
        }
        details.append(Detail(key: "Kind", value: traits(of: connection).joined(separator: ", ")))
        return details
    }

    private static func traits(of connection: Connection) -> [String] {
        let kind: String
        switch connection.endpoint {
        case .webDAV: kind = "WebDAV"
        case .sftp: kind = "SFTP"
        case .localFolder: kind = "local"
        }
        var parts = [kind, connection.isEncrypted ? "encrypted" : "plain"]
        if connection.isReadOnly { parts.append("read-only") }
        return parts
    }

    /// Security tools often scan every file they're shown, which makes previews download.
    private static let knownMonitors = [
        "com.crowdstrike": "CrowdStrike",
        "com.sentinelone": "SentinelOne",
        "com.objective-see": "Objective-See tools",
        "com.sophos": "Sophos",
        "com.malwarebytes": "Malwarebytes",
        "com.bitdefender": "Bitdefender",
        "com.eset": "ESET",
        "com.nortonlifelock": "Norton",
    ]

    public static func monitoringApps(running bundleIdentifiers: [String]) -> [String] {
        let found = knownMonitors.filter { prefix, _ in
            bundleIdentifiers.contains { $0.hasPrefix(prefix) }
        }
        return found.values.sorted()
    }
}
