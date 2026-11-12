// Apache 2 license - developer@infinitecontext.com

import Foundation

/// What a QR code carries to set up a drive on another device: everything except secrets.
/// A photo of the screen can't open the drive, because no password or key is ever in here.
public struct ConnectionSetup: Codable, Equatable, Sendable {
    public enum SetupError: Error, Equatable {
        /// The code isn't one of ours.
        case notASetupCode
        /// The code came from a newer version of the app.
        case newerFormat
    }

    /// What the scanned drive needs that the code can't carry.
    public enum NeededSecret: Equatable, Sendable {
        case serverPassword
        case encryptionPassword
        /// The drive signs in with a key, which is imported on the device, never scanned.
        case privateKey
    }

    private static let prefix = "cloudaccess-setup:"
    public static let currentFormat = 1

    public var format: Int
    public var name: String
    public var endpoint: Connection.Endpoint
    public var username: String
    public var rootPath: String
    public var isEncrypted: Bool
    public var vaultID: String?
    public var vaultRevision: Int?
    public var hostKey: String?
    /// Says that a key is needed, without carrying it.
    public var signsInWithKey: Bool

    public init(connection: Connection, signsInWithKey: Bool = false) {
        format = Self.currentFormat
        name = connection.displayName
        endpoint = connection.endpoint
        username = connection.username
        rootPath = connection.rootPath
        isEncrypted = connection.isEncrypted
        vaultID = connection.vaultID
        vaultRevision = connection.vaultRevision
        hostKey = connection.hostKey
        self.signsInWithKey = signsInWithKey
    }

    /// The text to put in the QR code. It isn't a URL, so only the app's own scanner reads it.
    public func encoded() throws -> String {
        Self.prefix + (try JSONEncoder().encode(self)).base64EncodedString()
    }

    /// Reads a scanned code. A scan is untrusted input, so it's held to the same rules as a
    /// typed address.
    public init(scanned text: String) throws {
        guard text.hasPrefix(Self.prefix),
              let data = Data(base64Encoded: String(text.dropFirst(Self.prefix.count))),
              data.count < 16_384
        else { throw SetupError.notASetupCode }

        let decoder = JSONDecoder()
        struct Version: Decodable { var format: Int }
        guard let version = try? decoder.decode(Version.self, from: data) else {
            throw SetupError.notASetupCode
        }
        guard version.format <= Self.currentFormat else { throw SetupError.newerFormat }
        guard var setup = try? decoder.decode(ConnectionSetup.self, from: data), setup.isValid else {
            throw SetupError.notASetupCode
        }
        // A scan goes through the same address rules as typing, so `HTTP://` is plain http.
        if case .webDAV(let url) = setup.endpoint, let server = ServerAddress(url.absoluteString) {
            setup.endpoint = server.endpoint
        }
        self = setup
    }

    private var isValid: Bool {
        guard !name.isEmpty, name.count <= 200 else { return false }
        switch endpoint {
        case .webDAV(let url):
            return ServerAddress(url.absoluteString) != nil
        case .sftp(let host, let port):
            return !host.isEmpty && (1...65_535).contains(port) && hostKey != nil
                && ServerFolder.sftp(rootPath) != nil
        case .localFolder:
            return false
        }
    }

    /// The drive this describes, with a new identity on this device.
    public func connection() -> Connection {
        var connection = Connection(
            displayName: name, endpoint: endpoint, username: username,
            rootPath: ServerFolder.tidied(rootPath, for: endpoint) ?? rootPath,
            isEncrypted: isEncrypted, hostKey: hostKey)
        connection.vaultID = vaultID
        connection.vaultRevision = vaultRevision
        return connection
    }

    /// A sign-in for the server, and an encrypted drive's own password, because they're
    /// separate secrets.
    public var neededSecrets: [NeededSecret] {
        let signIn: NeededSecret = signsInWithKey ? .privateKey : .serverPassword
        return isEncrypted ? [signIn, .encryptionPassword] : [signIn]
    }
}
