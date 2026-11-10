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

    /// Where a drive is and what kind it is, in English, as diagnostics and support read it.
    public static func details(of connection: Connection) -> [Detail] {
        details(of: connection, word: { $0 })
    }

    /// The same, in the language shown, for the side panel.
    public static func shownDetails(of connection: Connection) -> [Detail] {
        details(of: connection, word: Words.text)
    }

    /// What kind of drive this is, in the language shown, such as "SFTP, encrypted".
    public static func shownKind(of connection: Connection) -> String {
        traits(of: connection, word: Words.text).joined(separator: ", ")
    }

    private static func details(of connection: Connection, word: (String) -> String) -> [Detail] {
        var details = [Detail(key: word("Address"), value: address(of: connection))]
        if !connection.username.isEmpty {
            details.append(Detail(key: word("User"), value: connection.username))
        }
        details.append(Detail(key: word("Kind"), value: traits(of: connection, word: word).joined(separator: ", ")))
        return details
    }

    /// - Parameter word: How an English word is said: as it is for diagnostics, or translated for
    ///   the screen. A protocol's name is the same in every language.
    private static func traits(of connection: Connection, word: (String) -> String = { $0 }) -> [String] {
        let kind: String
        switch connection.endpoint {
        case .webDAV: kind = "WebDAV"
        case .sftp: kind = "SFTP"
        case .localFolder: kind = word("local")
        }
        var parts = [kind, word(connection.isEncrypted ? "encrypted" : "plain")]
        if connection.isReadOnly { parts.append(word("read-only")) }
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
