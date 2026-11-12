// Apache 2 license - developer@infinitecontext.com

import Foundation

/// Plain descriptions of a drive, safe to show and to include in diagnostics.
public enum ConnectionSummary {
    /// An address a person can read, in the form `ServerAddress` reads back, so it can be pasted.
    /// On SFTP a folder in the home folder is `sftp://host/~/Documents`, and one from the server's
    /// top is `sftp://host/Documents`. The usual port is left out. Connections never hold
    /// secrets, so this can't leak one.
    public static func address(of connection: Connection) -> String {
        switch connection.endpoint {
        case .webDAV(let url):
            return url.absoluteString
        case .sftp(let host, let port):
            // A colon in a host can only be IPv6, which an address has to bracket.
            var address = "sftp://" + (host.contains(":") ? "[\(host)]" : host)
            if port != 22 {
                address += ":\(port)"
            }
            // Encoded as WebDAV's address is, so a space can be pasted back. The plain-words
            // line beside it shows the folder as it's named.
            let tidy = ServerFolder.sftp(connection.rootPath) ?? connection.rootPath
            let folder = tidy.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? tidy
            if folder.hasPrefix("/") {
                address += folder
            } else if !folder.isEmpty {
                address += "/~/" + folder
            }
            return address
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

    /// The same, in the language shown, for the side panel. On SFTP it also says where the folder
    /// is in plain words, because `sftp://host/Documents` and `sftp://host/~/Documents` are two
    /// different folders that look alike.
    public static func shownDetails(of connection: Connection) -> [Detail] {
        var shown = details(of: connection, word: Words.text)
        if let place = ServerFolder.shownPlace(of: connection) {
            shown.insert(Detail(key: Words.text("Folder"), value: place), at: 1)
        }
        return shown
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
