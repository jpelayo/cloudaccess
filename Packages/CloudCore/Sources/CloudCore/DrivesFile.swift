// Apache 2 license - developer@infinitecontext.com

import CommonCrypto
import CryptoKit
import Foundation
import Security
import UniformTypeIdentifiers

/// Drives and their passwords, sealed with one password, to move them to another Mac or iPhone.
/// It's made only when a person asks, and nothing in it can be read without that password.
///
/// It's a type of its own, not part of the setup code, because the setup code must never hold a
/// secret (`aCodeHoldsNoSecrets`). The key comes from the password with PBKDF2-HMAC-SHA256, and the
/// drives are sealed with AES-256-GCM, with the file's header as authenticated data, so a changed
/// header is refused as surely as a changed body.
public enum DrivesFile {
    public static let fileExtension = "cadrives"
    public static let typeIdentifier = "com.infinitecontext.cloudaccess.drives"
    public static let currentFormat = 1
    /// A password a person types must be at least this long. The offered one is far longer.
    public static let shortestPassword = 12

    static let kind = "CloudAccess drives"
    static let algorithm = "PBKDF2-HMAC-SHA256"
    static let cipher = "AES-256-GCM"
    /// OWASP's figure for PBKDF2-HMAC-SHA256 in 2023.
    static let rounds = 600_000
    /// Reading refuses work far outside what this build writes, so a crafted file can't stall it.
    static let roundsAccepted = 100_000...5_000_000
    static let largestFile = 10 * 1_000_000

    public enum FileError: WordedError, Equatable {
        case notADrivesFile
        case newerFormat
        case wrongPasswordOrChanged
        case passwordTooShort
        case nothingToExport

        /// In the language shown.
        public var errorDescription: String? {
            wording.shown
        }

        public var englishDescription: String {
            wording.english
        }

        private var wording: Wording {
            switch self {
            case .notADrivesFile: Wording("This isn't a CloudAccess drives file.")
            case .newerFormat: Wording("This drives file needs a newer version of the app.")
            case .wrongPasswordOrChanged: Wording("The password is wrong, or the file was changed since it was made.")
            case .passwordTooShort: Wording("The password needs at least %lld characters.", DrivesFile.shortestPassword)
            case .nothingToExport: Wording("Choose at least one drive.")
            }
        }
    }

    /// One drive as the file carries it. Its ID, its state on the device, and consent to plain
    /// http stay behind: each device has its own.
    public struct Entry: Codable, Sendable, Equatable {
        public var name: String
        public var endpoint: Connection.Endpoint
        public var username: String
        public var rootPath: String
        public var isEncrypted: Bool
        public var vaultID: String?
        public var vaultRevision: Int?
        public var hostKey: String?
        public var settings: DriveSettings
        public var credentials: Credentials

        public init(_ connection: Connection, credentials: Credentials) {
            name = connection.displayName
            endpoint = connection.endpoint
            username = connection.username
            rootPath = connection.rootPath
            isEncrypted = connection.isEncrypted
            vaultID = connection.vaultID
            vaultRevision = connection.vaultRevision
            hostKey = connection.hostKey
            settings = connection.settings
            self.credentials = credentials
        }

        /// The drive as a new one on this device, with an ID of its own. Its folder is tidied
        /// the way a typed one is, so another device's spelling can't make it a second drive.
        public func connection(named displayName: String? = nil) -> Connection {
            var connection = Connection(
                displayName: displayName ?? name, endpoint: endpoint, username: username,
                rootPath: ServerFolder.tidied(rootPath, for: endpoint) ?? rootPath,
                isEncrypted: isEncrypted, hostKey: hostKey)
            connection.vaultID = vaultID
            connection.vaultRevision = vaultRevision
            connection.settings = settings
            return connection
        }

        /// Where the drive is, for a person to recognise it, as an address. No passwords.
        public var shownAddress: String {
            ConnectionSummary.address(of: connection())
        }

        /// The address, then on SFTP where its folder is in plain words, on a line of its own,
        /// such as "Documents, in the home folder". The two SFTP folders look alike otherwise.
        public var shownLocation: String {
            guard let place = ServerFolder.shownPlace(of: connection()) else { return shownAddress }
            return shownAddress + "\n" + place
        }
    }

    struct Contents: Codable {
        var created: Date
        var drives: [Entry]
    }

    /// What's written in the clear. Its encoding is what the seal authenticates.
    struct Header: Codable, Equatable {
        var kind: String
        var format: Int
        var algorithm: String
        var rounds: Int
        var salt: Data
        var cipher: String
    }

    struct Envelope: Codable {
        var header: Header
        var sealed: Data
    }

    /// Seals drives into a file's bytes.
    public static func seal(_ drives: [Entry], password: String, now: Date = Date()) throws -> Data {
        guard !drives.isEmpty else { throw FileError.nothingToExport }
        guard password.count >= shortestPassword else { throw FileError.passwordTooShort }
        var salt = Data(count: 32)
        let status = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        guard status == errSecSuccess else { throw FileError.wrongPasswordOrChanged }
        let header = Header(
            kind: kind, format: currentFormat, algorithm: algorithm, rounds: rounds, salt: salt, cipher: cipher)
        let key = try deriveKey(password: password, salt: salt, rounds: rounds)
        let body = try encoder.encode(Contents(created: now, drives: drives))
        let box = try AES.GCM.seal(body, using: key, authenticating: encoder.encode(header))
        guard let sealed = box.combined else { throw FileError.wrongPasswordOrChanged }
        return try encoder.encode(Envelope(header: header, sealed: sealed))
    }

    /// Opens a file's bytes. Nothing is returned unless the whole file is exactly as it was sealed.
    public static func open(_ data: Data, password: String) throws -> [Entry] {
        guard data.count <= largestFile,
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.header.kind == kind
        else { throw FileError.notADrivesFile }
        let header = envelope.header
        guard header.format <= currentFormat else { throw FileError.newerFormat }
        guard header.algorithm == algorithm, header.cipher == cipher, roundsAccepted.contains(header.rounds),
              header.salt.count >= 16
        else { throw FileError.notADrivesFile }
        let key = try deriveKey(password: password, salt: header.salt, rounds: header.rounds)
        do {
            let box = try AES.GCM.SealedBox(combined: envelope.sealed)
            let body = try AES.GCM.open(box, using: key, authenticating: encoder.encode(header))
            return try JSONDecoder.withDates.decode(Contents.self, from: body).drives
        } catch {
            throw FileError.wrongPasswordOrChanged
        }
    }

    /// The name a new file is offered under, such as "CloudAccess Drives 2026-11-10.cadrives".
    public static func suggestedName(now: Date = Date()) -> String {
        "CloudAccess Drives \(now.ISO8601Format(.iso8601.year().month().day())).\(fileExtension)"
    }

    /// Sorted keys, so the header's bytes are the same when the file is opened as when it was sealed.
    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func deriveKey(password: String, salt: Data, rounds: Int) throws -> SymmetricKey {
        let secret = Array(password.utf8)
        var key = [UInt8](repeating: 0, count: kCCKeySizeAES256)
        let status = salt.withUnsafeBytes { saltBytes in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2), password, secret.count,
                saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(rounds),
                &key, key.count)
        }
        guard status == kCCSuccess else { throw FileError.wrongPasswordOrChanged }
        defer { key.withUnsafeMutableBytes { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) } }
        return SymmetricKey(data: key)
    }
}

extension UTType {
    /// A drives file. Each app declares it in its Info.plist, so the file opens there and AirDrop
    /// offers it.
    public static let drivesFile = UTType(exportedAs: DrivesFile.typeIdentifier, conformingTo: .data)
}

private extension JSONDecoder {
    static var withDates: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
