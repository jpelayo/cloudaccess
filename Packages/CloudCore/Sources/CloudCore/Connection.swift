// Apache 2 license - developer@infinitecontext.com

import Foundation

/// A saved drive. Contains no secrets: those live in the Keychain as `Credentials`.
public struct Connection: Identifiable, Hashable, Sendable, Codable {
    public enum Endpoint: Hashable, Sendable, Codable {
        case webDAV(url: URL)
        case sftp(host: String, port: Int)
        /// A folder on this device, for offline tests.
        case localFolder
    }

    public var id: UUID
    public var displayName: String
    public var endpoint: Endpoint
    public var username: String
    /// The folder on the server that appears as the top of the drive.
    public var rootPath: String
    /// Declared at setup and can't change afterwards.
    public var isEncrypted: Bool
    /// Pinned on first success, so this drive can't silently switch to another vault.
    public var vaultID: String?
    public var vaultRevision: Int?
    /// An SFTP server's key, confirmed by a person and pinned on first use.
    public var hostKey: String?
    /// Nil until someone changes a setting, and it reads as the defaults.
    public var storedSettings: DriveSettings?
    /// Nil means active. A drive being added or removed keeps its state through a crash.
    public var storedLifecycle: Lifecycle?
    /// Nil means mounted. An ejected drive keeps its connection and passwords.
    public var storedIsMounted: Bool?
    /// Nil means no. A person's consent to send the password readably over plain http.
    public var storedAllowsInsecure: Bool?
    /// Nil means no. Found when the drive is added, and separate from anyone's choice.
    public var storedServerIsReadOnly: Bool?

    /// The server can't take saves safely, or refuses them, whatever anyone chooses.
    public var serverIsReadOnly: Bool {
        get { storedServerIsReadOnly ?? false }
        set { storedServerIsReadOnly = newValue ? true : nil }
    }

    /// Whether anything may be written, by a person's choice or the server's limit.
    public var isReadOnly: Bool {
        settings.isReadOnly || serverIsReadOnly
    }

    /// A setup code can't carry this, so a person gives it on each device.
    public var allowsInsecure: Bool {
        get { storedAllowsInsecure ?? false }
        set { storedAllowsInsecure = newValue ? true : nil }
    }

    /// Whether the drive is in Finder and syncing.
    public var isMounted: Bool {
        get { storedIsMounted ?? true }
        set { storedIsMounted = newValue ? nil : false }
    }

    public var settings: DriveSettings {
        get { storedSettings ?? DriveSettings() }
        set { storedSettings = newValue }
    }

    public var lifecycle: Lifecycle {
        get { storedLifecycle ?? .active }
        set { storedLifecycle = newValue == .active ? nil : newValue }
    }

    /// Where a drive is in being set up or taken down.
    public enum Lifecycle: String, Hashable, Sendable, Codable {
        case adding
        case active
        case removing
    }

    public init(
        id: UUID = UUID(),
        displayName: String,
        endpoint: Endpoint,
        username: String = "",
        rootPath: String = "",
        isEncrypted: Bool = false,
        hostKey: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.endpoint = endpoint
        self.username = username
        self.rootPath = rootPath
        self.isEncrypted = isEncrypted
        self.hostKey = hostKey
    }

    /// Whether a change needs a different local drive. Renaming a connection or updating
    /// a password must never touch local files, so only the server location qualifies. Another
    /// account on the same server sees different files, so that's a location too.
    public func requiresNewDrive(comparedTo other: Connection) -> Bool {
        endpoint.location != other.endpoint.location
            || Self.withoutTrailingSlash(rootPath) != Self.withoutTrailingSlash(other.rootPath)
            || username != other.username
    }

    fileprivate static func withoutTrailingSlash(_ path: String) -> String {
        var trimmed = Substring(path)
        while trimmed.hasSuffix("/") {
            trimmed = trimmed.dropLast()
        }
        return String(trimmed)
    }

    #if DEBUG
    /// Test builds only accept a folder with this name, so they can't reach real data.
    public static let testFolderName = "cloudmount-test"

    public static func isTestFolder(path: String) -> Bool {
        (path as NSString).lastPathComponent == testFolderName
    }

    public static func isTestFolder(_ url: URL) -> Bool {
        url.lastPathComponent == testFolderName
    }

    /// Whether this drive points at a test folder, the only kind debug hooks may touch.
    public var isTestDrive: Bool {
        switch endpoint {
        case .webDAV(let url): Self.isTestFolder(url)
        case .sftp: Self.isTestFolder(path: rootPath)
        case .localFolder: false
        }
    }
    #endif
}

extension Connection.Endpoint {
    /// Where this leads, the same however it was written. Letter case in a host, a default port
    /// and a trailing slash don't make it another server, or two drives could share one folder.
    public var location: String {
        switch self {
        case .webDAV(let url):
            let scheme = url.scheme?.lowercased() ?? ""
            let port = url.port ?? (scheme == "https" ? 443 : 80)
            let path = Connection.withoutTrailingSlash(url.path)
            return "\(scheme)://\(url.host?.lowercased() ?? ""):\(port)\(path)"
        case .sftp(let host, let port):
            return "sftp://\(host.lowercased()):\(port)"
        case .localFolder:
            return "local"
        }
    }

    /// Whether a password would cross the network readably. The scheme's case doesn't matter,
    /// because a URL keeps whatever case it was written in.
    public var isInsecure: Bool {
        if case .webDAV(let url) = self {
            return url.scheme?.lowercased() == "http"
        }
        return false
    }
}

/// What stays on this device. Files are always safe on the server, so these only decide how
/// much space a drive takes here. Files with unsent changes are never removed.
public struct DriveSettings: Hashable, Sendable, Codable {
    /// Removes a local copy after this long with no download or local change. Nil keeps it.
    public var removeLocalCopyAfter: TimeInterval? = 3600
    /// Removes the oldest local copies above this many bytes. Nil means no limit.
    public var sizeLimit: Int64? = 10 * 1_000_000_000
    /// Offers no writes, and refuses them on every path.
    public var isReadOnly = false
    /// Local copies are removed to keep this many bytes of the disk free. Nil means no reserve.
    public var diskReserve: Int64? = 5 * 1_000_000_000
    /// Thumbnails are fetched for files up to this size. Nil turns them off.
    public var thumbnailLimit: Int64? = 20 * 1_000_000
    /// How often to check folders in recent use, in seconds.
    public var recentFolderInterval: TimeInterval = 60
    /// How often to check every other listed folder, in seconds.
    public var otherFolderInterval: TimeInterval = 1800
    /// How many files upload at once. It applies from the drive's next connection.
    public var uploadsAtOnce = 4

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case removeLocalCopyAfter, sizeLimit, isReadOnly, diskReserve, thumbnailLimit
        case recentFolderInterval, otherFolderInterval, uploadsAtOnce
    }

    /// Missing values read as nil or off, so a setting added later can't fail to load.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        removeLocalCopyAfter = try values.decodeIfPresent(TimeInterval.self, forKey: .removeLocalCopyAfter)
        sizeLimit = try values.decodeIfPresent(Int64.self, forKey: .sizeLimit)
        isReadOnly = try values.decodeIfPresent(Bool.self, forKey: .isReadOnly) ?? false
        diskReserve = try values.decodeIfPresent(Int64.self, forKey: .diskReserve)
        thumbnailLimit = try values.decodeIfPresent(Int64.self, forKey: .thumbnailLimit)
        recentFolderInterval = try values.decodeIfPresent(TimeInterval.self, forKey: .recentFolderInterval) ?? 60
        otherFolderInterval = try values.decodeIfPresent(TimeInterval.self, forKey: .otherFolderInterval) ?? 1800
        uploadsAtOnce = try values.decodeIfPresent(Int.self, forKey: .uploadsAtOnce) ?? 4
    }
}

/// This device, as other devices see it.
public struct DeviceInfo: Sendable {
    /// Separates this device's staging files on the server.
    public var id: String
    /// Labels conflict copies, such as "MacBook".
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// The secrets for a connection, held in memory only after leaving the Keychain.
public struct Credentials: Sendable, Codable {
    public var password: String?
    public var privateKeyPEM: String?
    public var privateKeyPassphrase: String?
    public var vaultPassword: String?

    public init(
        password: String? = nil,
        privateKeyPEM: String? = nil,
        privateKeyPassphrase: String? = nil,
        vaultPassword: String? = nil
    ) {
        self.password = password
        self.privateKeyPEM = privateKeyPEM
        self.privateKeyPassphrase = privateKeyPassphrase
        self.vaultPassword = vaultPassword
    }
}

/// What a typed address means. The protocol comes from the address, so nobody has to pick it.
public struct ServerAddress: Equatable, Sendable {
    public var endpoint: Connection.Endpoint
    /// The folder on an SFTP server. WebDAV keeps its folder in the URL.
    public var rootPath: String
    /// Plain HTTP sends the password readably, so it needs an explicit acknowledgement.
    public var isInsecure = false

    /// - Returns: `nil` for anything but `https`, `http` or `sftp`, for an address with a name
    ///   or password in it, because those would end up in logs and settings, and for a query
    ///   or fragment, which would swallow the file paths added to the address.
    public init?(_ text: String) {
        guard var components = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              let host = components.host, !host.isEmpty,
              let scheme = components.scheme?.lowercased()
        else { return nil }

        switch scheme {
        case "https", "http":
            components.scheme = scheme
            guard let url = components.url else { return nil }
            endpoint = .webDAV(url: url)
            rootPath = ""
            isInsecure = scheme == "http"
        case "sftp":
            endpoint = .sftp(host: host, port: components.port ?? 22)
            // sftp://host/~/docs means docs in the user's home folder.
            let path = components.path
            rootPath = path.hasPrefix("/~/") ? String(path.dropFirst(3)) : path
        default:
            return nil
        }
    }
}
