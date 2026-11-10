// Apache 2 license - developer@infinitecontext.com

import Foundation

/// A file or folder on a drive.
public struct RemoteItem: Hashable, Sendable, Codable {
    public enum Kind: String, Sendable, Codable {
        case file
        case directory
    }

    public var path: RemotePath
    public var kind: Kind
    public var size: Int64?
    /// The server's own date. On WebDAV that's when the file arrived, not the file's own date.
    public var modified: Date?
    /// A fixed-size ID for this exact version, or `nil` if the server gives no evidence of
    /// one. macOS stores it and hands it back as the base of an edit.
    public var versionID: String?

    // What the file's details say, kept beside it on servers that allow it. Each is nil when the
    // server keeps none, or the details no longer describe this version. None of them is part of
    // the version, because writing details never changes the file.

    /// The file's own modification date, as the device that saved it had it.
    public var ownModified: Date?
    /// When the file or folder was created, as the device that made it had it.
    public var created: Date?
    /// The SHA-256 of the original bytes, before any encryption, in lowercase hex.
    public var checksum: String?
    /// A flattened macOS package's type identifier, such as `com.apple.iwork.numbers.numbers`.
    public var bundleType: String?

    public init(
        path: RemotePath,
        kind: Kind,
        size: Int64? = nil,
        modified: Date? = nil,
        versionID: String? = nil,
        ownModified: Date? = nil,
        created: Date? = nil,
        checksum: String? = nil,
        bundleType: String? = nil
    ) {
        self.path = path
        self.kind = kind
        self.size = size
        self.modified = modified
        self.versionID = versionID
        self.ownModified = ownModified
        self.created = created
        self.checksum = checksum
        self.bundleType = bundleType
    }

    /// The date to show and sort by: the file's own when its details say, otherwise the server's.
    public var shownModified: Date? {
        ownModified ?? modified
    }

    /// Changes whenever the server's copy changes. Folders have no content version. File details
    /// are left out: they're written after the file, and never change it.
    public var versionToken: String {
        guard kind == .file else { return "" }
        let time = modified.map { String(format: "%.3f", $0.timeIntervalSince1970) } ?? "-"
        return "\(size ?? -1)|\(time)|\(versionID ?? "-")"
    }
}

/// How a save ended.
public struct SaveResult: Sendable, Equatable {
    /// The item now at the requested path. After a conflict, that's the peer's version.
    public var item: RemoteItem
    /// Where our version went, if a peer saved first.
    public var conflictCopy: RemotePath?
    /// Why the file was saved without its details, for the log. The save itself stands.
    public var detailsMissed: String?

    public init(item: RemoteItem, conflictCopy: RemotePath? = nil, detailsMissed: String? = nil) {
        self.item = item
        self.conflictCopy = conflictCopy
        self.detailsMissed = detailsMissed
    }
}

/// What the saving device knows about a file. A server that keeps file details stores this
/// beside the file. None of it decides anything about the save.
public struct FileDetails: Sendable, Equatable {
    public var modified: Date?
    public var created: Date?
    /// A flattened package's type identifier, as macOS gives it.
    public var bundleType: String?

    public init(modified: Date? = nil, created: Date? = nil, bundleType: String? = nil) {
        self.modified = modified
        self.created = created
        self.bundleType = bundleType
    }
}

/// An upload that's on the server, waiting to be put in place.
public struct StagedUpload: Sendable, Equatable {
    public var token: String

    public init(token: String) {
        self.token = token
    }
}

/// The operations every storage engine provides. Everything above this layer works the
/// same whether a drive is encrypted, and whichever engine serves it.
public protocol RemoteBackend: Sendable {
    /// Asks the server something real, and checks an encrypted drive's vault hasn't changed.
    /// Throws if the drive can't be used.
    func checkHealth() async throws

    /// Whether the server reports versions, without which a save can't safely replace a file.
    /// This writes a small file inside the drive's control folder, never among user files.
    func reportsVersions() async throws -> Bool

    /// Throws `RemoteError.notFound` if nothing exists at `path`.
    func item(at path: RemotePath) async throws -> RemoteItem

    /// The direct children of a folder.
    func list(_ path: RemotePath) async throws -> [RemoteItem]

    /// Downloads a whole file to a local URL, replacing anything already there.
    func download(_ path: RemotePath, to destination: URL) async throws

    /// Writes part of a file to a local URL.
    func read(_ path: RemotePath, offset: Int64, length: Int64, to destination: URL) async throws

    /// Uploads a local file with no version protection. Saves should use `save`.
    @discardableResult
    func upload(from source: URL, to path: RemotePath) async throws -> RemoteItem

    /// Uploads a local file to the side, with nothing locked and nothing at risk. This is the
    /// slow part of a save, and the file's place is only worked out once it's done, because a
    /// folder above it can move during a long upload.
    func stage(from source: URL) async throws -> StagedUpload

    /// Puts a staged upload in place so that a peer's version is never overwritten. If the
    /// server already holds exactly these bytes, as after a replay, nothing is written.
    /// - Parameters:
    ///   - source: The local file, for comparing with what's on the server.
    ///   - baseVersion: The version this edit started from. `nil` means a new file, or no
    ///     agreed version, so an existing file is kept and ours becomes a conflict copy.
    ///   - failOnConflict: Throws `RemoteError.versionMismatch` instead of keeping both.
    @discardableResult
    func commit(
        _ staged: StagedUpload, source: URL, to path: RemotePath, baseVersion: String?, failOnConflict: Bool
    ) async throws -> SaveResult

    /// Clears a staged upload that won't be committed.
    func discard(_ staged: StagedUpload) async

    /// Refuses a name the server can't hold. It's asked before an upload, because the upload can't
    /// end up anywhere under that name, however long it takes.
    func checkName(_ path: RemotePath) async throws

    /// Creates a folder and any missing parents.
    func createDirectory(_ path: RemotePath) async throws

    /// Moves a file or folder on the server without re-uploading it, and refuses to
    /// replace anything at the destination.
    /// - Parameter baseVersion: The version macOS last saw. A replay finds its source gone, and
    ///   only this proves that what's at the destination is the same item, and not a peer's.
    @discardableResult
    func move(from source: RemotePath, to destination: RemotePath, baseVersion: String?) async throws -> RemoteItem

    /// Deletes a file, or a folder and everything in it, permanently.
    func delete(_ path: RemotePath) async throws

    /// Moves an item to the server's trash. Throws `RemoteError.versionMismatch` if the
    /// file isn't `baseVersion`, so a peer's edit can't be trashed unseen.
    func trash(_ path: RemotePath, baseVersion: String?) async throws

    /// `commit`, with what this device knows about the file for its details.
    @discardableResult
    func commit(
        _ staged: StagedUpload, source: URL, to path: RemotePath, baseVersion: String?, failOnConflict: Bool,
        details: FileDetails
    ) async throws -> SaveResult

    /// `createDirectory`, recording when the folder was created here. A folder another device
    /// made first keeps its own date.
    func createDirectory(_ path: RemotePath, created: Date?) async throws

    /// `download`, failing rather than keeping bytes that don't match the file's recorded checksum.
    func download(_ path: RemotePath, to destination: URL, checksum: String?) async throws
}

extension RemoteBackend {
    // A backend that keeps no file details takes them and does what it always did.

    @discardableResult
    public func commit(
        _ staged: StagedUpload, source: URL, to path: RemotePath, baseVersion: String?, failOnConflict: Bool,
        details: FileDetails
    ) async throws -> SaveResult {
        try await commit(staged, source: source, to: path, baseVersion: baseVersion, failOnConflict: failOnConflict)
    }

    public func createDirectory(_ path: RemotePath, created: Date?) async throws {
        try await createDirectory(path)
    }

    public func download(_ path: RemotePath, to destination: URL, checksum: String?) async throws {
        try await download(path, to: destination)
    }
}

extension RemoteBackend {
    /// Stages and commits a file whose place can't change during the upload.
    @discardableResult
    public func save(
        from source: URL, to path: RemotePath, baseVersion: String?, failOnConflict: Bool = false
    ) async throws -> SaveResult {
        let staged = try await stage(from: source)
        do {
            return try await commit(
                staged, source: source, to: path, baseVersion: baseVersion, failOnConflict: failOnConflict)
        } catch {
            await discard(staged)
            throw error
        }
    }

    @discardableResult
    public func move(from source: RemotePath, to destination: RemotePath) async throws -> RemoteItem {
        try await move(from: source, to: destination, baseVersion: nil)
    }

    /// Downloads a file, and reports the version of exactly those bytes. If it changes during the
    /// download, what arrived may be a mix, so it's fetched again. So is a file that came out a
    /// different size from the one listed: a stream can end early and cleanly, and every chunk of
    /// an encrypted file that did arrive still authenticates.
    /// - Parameter stage: Hears each step as it starts, for someone watching it happen.
    public func verifiedDownload(
        _ path: RemotePath, to destination: URL, stage: (@Sendable (DownloadStage) -> Void)? = nil
    ) async throws -> RemoteItem {
        var isIncomplete = false
        for _ in 1...2 {
            stage?(.checking)
            let before = try await item(at: path)
            stage?(.downloading)
            do {
                // With a recorded checksum, bytes that don't match it are never kept.
                try await download(path, to: destination, checksum: before.checksum)
            } catch where before.checksum != nil && !(error is CancellationError) {
                // A peer's save landing during the download looks the same, and is fetched again.
                if let now = try? await item(at: path), now.versionToken != before.versionToken {
                    continue
                }
                throw error
            }
            stage?(.verifying)
            let after = try await item(at: path)
            guard before.versionToken == after.versionToken else { continue }
            let arrived = (try? FileManager.default.attributesOfItem(atPath: destination.path))?[.size] as? Int64
            isIncomplete = after.size != nil && arrived != after.size
            if !isIncomplete {
                return after
            }
        }
        if isIncomplete {
            try? FileManager.default.removeItem(at: destination)
            // One sentence for every file, so it can be translated: the file's name is beside it
            // wherever it's shown.
            throw RemoteError.failed(path, "The server didn't send all of this file.")
        }
        throw RemoteError.locked(path)
    }
}

/// The steps of a verified download, as someone watching sees them.
public enum DownloadStage: Sendable, Equatable {
    /// Asking the server which version is there.
    case checking
    /// The bytes are coming down, decrypted on the way if the drive is encrypted.
    case downloading
    /// Asking again, to be sure the file didn't change while it came down.
    case verifying
}
