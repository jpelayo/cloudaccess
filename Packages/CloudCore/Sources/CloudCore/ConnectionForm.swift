// Apache 2 license - developer@infinitecontext.com

import Foundation

/// A drive's connection as the fields a person edits. Fields become a connection through the same
/// checks as a typed address, so an edit can't reach anything an address couldn't.
public struct ConnectionForm: Equatable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case https = "WebDAV (https)"
        case http = "WebDAV (http)"
        case sftp = "SFTP"

        /// The protocol as a person reads it. The raw value is what's compared and saved, so it
        /// never changes with the language.
        public var title: String {
            Words.text(rawValue)
        }

        fileprivate var scheme: String {
            switch self {
            case .https: "https"
            case .http: "http"
            case .sftp: "sftp"
            }
        }

        public var defaultPort: String {
            switch self {
            case .https: "443"
            case .http: "80"
            case .sftp: "22"
            }
        }
    }

    public var name: String
    public var kind: Kind
    public var host: String
    /// Blank means the protocol's usual port.
    public var port: String
    public var path: String
    public var username: String

    /// A blank form for a new drive. WebDAV over https is what most servers want.
    public init() {
        name = ""
        kind = .https
        host = ""
        port = ""
        path = ""
        username = ""
    }

    public init(_ connection: Connection) {
        name = connection.displayName
        username = connection.username
        switch connection.endpoint {
        case .webDAV(let url):
            kind = url.scheme?.lowercased() == "http" ? .http : .https
            host = url.host ?? ""
            port = url.port.map(String.init) ?? ""
            path = url.path
        case .sftp(let host, let port):
            kind = .sftp
            self.host = host
            self.port = String(port)
            path = connection.rootPath
        case .localFolder:
            kind = .https
            host = ""
            port = ""
            path = connection.rootPath
        }
    }

    /// Whether these fields point somewhere other than the saved connection does.
    private func isSameLocation(as other: ConnectionForm) -> Bool {
        kind == other.kind && host == other.host && port == other.port
            && path == other.path && username == other.username
    }

    /// The address these fields make, or nil if they don't make a valid one.
    private var server: ServerAddress? {
        let trimmedHost = host.trimmingCharacters(in: .whitespaces)
        guard !trimmedHost.isEmpty, trimmedHost.allSatisfy({ !"/?#@ ".contains($0) }) else { return nil }
        var address = "\(kind.scheme)://"
        // A colon here can only mean an IPv6 address, which an address has to bracket.
        address += trimmedHost.contains(":") ? "[\(trimmedHost)]" : trimmedHost
        if !port.isEmpty {
            guard let number = Int(port), (1...65_535).contains(number), String(number) == port else { return nil }
            address += ":\(number)"
        }
        guard let folder = path.addingPercentEncoding(withAllowedCharacters: Self.pathCharacters) else { return nil }
        if !folder.isEmpty {
            // On SFTP a path with no leading slash is inside the user's home folder.
            address += folder.hasPrefix("/") ? folder : (kind == .sftp ? "/~/" : "/") + folder
        }
        return ServerAddress(address)
    }

    /// `?` and `#` are ordinary characters in a folder's name, not parts of an address.
    private static let pathCharacters = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "?#"))

    /// The connection these fields describe, or nil if they don't make one. Fields left alone
    /// keep the saved values exactly, because rebuilding an address can respell it, and a
    /// respelled address would look like a move.
    public func applied(to connection: Connection) -> Connection? {
        let newName = name.trimmingCharacters(in: .whitespaces)
        guard !newName.isEmpty else { return nil }
        var edited = connection
        edited.displayName = newName
        guard !isSameLocation(as: ConnectionForm(connection)) else { return edited }
        guard let server else { return nil }
        edited.endpoint = server.endpoint
        edited.rootPath = server.rootPath
        edited.username = username
        // Trust belongs to a server and a vault to a folder, so neither carries over.
        if edited.endpoint != connection.endpoint {
            edited.hostKey = nil
        }
        edited.vaultID = nil
        edited.vaultRevision = nil
        return edited
    }

    /// Reads a whole address typed or pasted as the host, so nobody has to split one up, or
    /// remember `https://`. A plain host stays a host on the chosen protocol. A password in an
    /// address is dropped, because it would end up in settings and logs.
    public mutating func tidyHost() {
        let text = host.trimmingCharacters(in: .whitespacesAndNewlines)
        host = text
        let hasScheme = text.contains("://")
        guard hasScheme || text.contains("/") || text.contains("@") || Self.endsInPort(text),
              let parts = URLComponents(string: hasScheme ? text : "\(kind.scheme)://\(text)"),
              let found = parts.host, !found.isEmpty
        else { return }
        if hasScheme {
            guard let scheme = Kind.allCases.first(where: { $0.scheme == parts.scheme?.lowercased() })
            else { return }
            kind = scheme
        }
        host = found
        if let number = parts.port {
            port = String(number)
        }
        var folder = parts.path
        while folder.hasSuffix("/") {
            folder.removeLast()
        }
        if !folder.isEmpty {
            path = folder
        }
        if username.isEmpty, let user = parts.user {
            username = user
        }
    }

    /// `example.com:2022` has a port. An IPv6 address has more than one colon, and doesn't.
    private static func endsInPort(_ text: String) -> Bool {
        let pieces = text.split(separator: ":", omittingEmptySubsequences: false)
        return pieces.count == 2 && !pieces[1].isEmpty && pieces[1].allSatisfy(\.isNumber)
    }

    /// A new drive from these fields, or nil if they don't make one.
    public func newConnection(isEncrypted: Bool, hostKey: String? = nil) -> Connection? {
        let newName = name.trimmingCharacters(in: .whitespaces)
        guard !newName.isEmpty, let server else { return nil }
        return Connection(
            displayName: newName, endpoint: server.endpoint,
            username: username.trimmingCharacters(in: .whitespaces),
            rootPath: server.rootPath, isEncrypted: isEncrypted, hostKey: hostKey)
    }

    /// These fields pointed at the server's top folder, to look around from.
    public var atTopFolder: ConnectionForm {
        var top = self
        top.path = ""
        return top
    }

    /// A connection for looking through folders. It's never saved, so it needs no name yet.
    public func browsingConnection(hostKey: String? = nil) -> Connection? {
        var form = self
        form.name = host
        return form.newConnection(isEncrypted: false, hostKey: hostKey)
    }

    /// A folder for a drive that needs its own, named after it. Blank if the name can't be one.
    public var ownFolderName: String {
        let folder = name.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "-")
        return RemotePath.isValidName(folder) && !RemotePath.isReservedName(folder) ? folder : ""
    }

    /// What the Folder field says for a folder chosen below this form's own.
    public func folderField(for folder: RemotePath) -> String {
        guard !folder.isRoot else { return path }
        let inside = folder.components.joined(separator: "/")
        var base = path
        while base.hasSuffix("/") {
            base.removeLast()
        }
        if !base.isEmpty {
            return "\(base)/\(inside)"
        }
        // On SFTP a path with no leading slash is inside the user's home folder, and that's the
        // top folder a person sees.
        return kind == .sftp ? inside : "/\(inside)"
    }

    /// Plain http sends the password readably, so moving to it needs a person's say-so.
    public func needsInsecureConsent(comparedTo connection: Connection) -> Bool {
        kind == .http && ConnectionForm(connection).kind != .http
    }
}

/// New sign-in details. A blank field keeps what's saved, so nobody retypes a password to rename a
/// drive, and the saved one never has to be shown.
public struct SignInEdit: Equatable, Sendable {
    public var password: String?
    public var privateKeyPEM: String?
    public var privateKeyPassphrase: String?

    public init(password: String? = nil, privateKeyPEM: String? = nil, privateKeyPassphrase: String? = nil) {
        self.password = password
        self.privateKeyPEM = privateKeyPEM
        self.privateKeyPassphrase = privateKeyPassphrase
    }

    public var isEmpty: Bool {
        password == nil && privateKeyPEM == nil
    }

    public func applied(to saved: Credentials) -> Credentials {
        var result = saved
        if let password {
            result.password = password
        }
        if let privateKeyPEM {
            result.privateKeyPEM = privateKeyPEM
            // A passphrase belongs to one key.
            result.privateKeyPassphrase = privateKeyPassphrase
        }
        return result
    }
}
