// Apache 2 license - developer@infinitecontext.com

import CryptoKit
import Foundation

/// What the iPhone keeps so it stays useful with no connection: folder listings it has seen, and
/// files it has downloaded. Downloads of an encrypted drive are decrypted here, so everything is
/// unreadable while the phone is locked, stays out of backups, and goes when the drive is removed.
public struct OfflineLibrary: Sendable {
    private let root: URL

    public init(directory: URL) {
        root = directory
    }

    private func folder(of drive: UUID) -> URL {
        root.appendingPathComponent(drive.uuidString)
    }

    /// Names can be long or contain anything, so they never become file names here.
    private func key(for path: RemotePath) -> String {
        SHA256.hash(data: Data(path.description.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func listingFile(of path: RemotePath, drive: UUID) -> URL {
        folder(of: drive).appendingPathComponent("listings").appendingPathComponent(key(for: path) + ".json")
    }

    private func fileFolder(of path: RemotePath, drive: UUID) -> URL {
        folder(of: drive).appendingPathComponent("files").appendingPathComponent(key(for: path))
    }

    /// Kept with the file, so the two can't disagree. Names starting `.cm-` are reserved on every
    /// drive, so no file can be called this.
    private static let versionRecord = ".cm-version"

    private func versionFile(of path: RemotePath, drive: UUID) -> URL {
        fileFolder(of: path, drive: drive).appendingPathComponent(Self.versionRecord)
    }

    private func makeFolder(_ url: URL) throws {
        var attributes: [FileAttributeKey: Any] = [:]
        #if os(iOS)
        attributes[.protectionKey] = FileProtectionType.complete
        #endif
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true, attributes: attributes)
        var top = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? top.setResourceValues(values)
    }

    // MARK: Listings

    public func save(listing items: [RemoteItem], of path: RemotePath, drive: UUID) throws {
        let file = listingFile(of: path, drive: drive)
        try makeFolder(file.deletingLastPathComponent())
        try JSONEncoder().encode(items).write(to: file, options: .atomic)
    }

    /// The last listing seen, or nil if this folder hasn't been opened here. A damaged listing
    /// counts as never seen.
    public func listing(of path: RemotePath, drive: UUID) -> [RemoteItem]? {
        guard let data = try? Data(contentsOf: listingFile(of: path, drive: drive)) else { return nil }
        return try? JSONDecoder().decode([RemoteItem].self, from: data)
    }

    public func hasListing(of path: RemotePath, drive: UUID) -> Bool {
        FileManager.default.fileExists(atPath: listingFile(of: path, drive: drive).path)
    }

    // MARK: Downloads

    /// A kept file, with its real name so an export keeps it too.
    public func download(of path: RemotePath, drive: UUID) -> URL? {
        let file = fileFolder(of: path, drive: drive).appendingPathComponent(path.name)
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    /// Where a download should go while it runs. It only counts once `keep` is called, so a
    /// cancelled or failed download can never pass for a finished one.
    public func temporaryFile(drive: UUID) throws -> URL {
        let incoming = folder(of: drive).appendingPathComponent("incoming")
        try makeFolder(incoming)
        return incoming.appendingPathComponent(UUID().uuidString)
    }

    /// Keeps a finished download, replacing any older one. The new copy is made complete beside
    /// the old one and swapped in, because this may be the only copy within reach: if anything
    /// fails, the old one is still there.
    /// - Parameter version: The version of these bytes, so a newer one can be noticed later.
    @discardableResult
    /// Gives a downloaded copy the file's own dates from its details, so a copy shared or saved to
    /// Files keeps them. Without details the copy keeps its own dates, which say when it arrived.
    public static func stamp(_ file: URL, with item: RemoteItem) {
        var attributes: [FileAttributeKey: Any] = [:]
        if let own = item.ownModified {
            attributes[.modificationDate] = own
        }
        if let created = item.created {
            attributes[.creationDate] = created
        }
        guard !attributes.isEmpty else { return }
        try? FileManager.default.setAttributes(attributes, ofItemAtPath: file.path)
    }

    public func keep(_ finished: URL, as path: RemotePath, drive: UUID, version: String? = nil) throws -> URL {
        let files = FileManager.default
        let target = fileFolder(of: path, drive: drive)
        let fresh = target.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try makeFolder(fresh)
        do {
            try files.moveItem(at: finished, to: fresh.appendingPathComponent(path.name))
            try version.map {
                try Data($0.utf8).write(to: fresh.appendingPathComponent(Self.versionRecord), options: .atomic)
            }
            if files.fileExists(atPath: target.path) {
                _ = try files.replaceItemAt(target, withItemAt: fresh)
            } else {
                try files.moveItem(at: fresh, to: target)
            }
        } catch {
            try? files.removeItem(at: fresh)
            throw error
        }
        return target.appendingPathComponent(path.name)
    }

    /// Clears what a killed download left behind. Nothing can be running when the app starts.
    public func clearAbandoned() {
        let files = FileManager.default
        let drives = (try? files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for drive in drives {
            try? files.removeItem(at: drive.appendingPathComponent("incoming"))
            let kept = drive.appendingPathComponent("files")
            // Kept files sit under a hash. Anything else is a copy that was never swapped in.
            for item in (try? files.contentsOfDirectory(at: kept, includingPropertiesForKeys: nil)) ?? []
            where item.lastPathComponent.count != 64 {
                try? files.removeItem(at: item)
            }
        }
    }

    /// Whether the server has something other than what's kept here. A kept file with no version
    /// on record counts as older, because a stale file that looks current is the worse mistake.
    public func isOutdated(_ path: RemotePath, drive: UUID, serverVersion: String?) -> Bool {
        guard let serverVersion, download(of: path, drive: drive) != nil else { return false }
        guard let kept = try? Data(contentsOf: versionFile(of: path, drive: drive)) else { return true }
        return String(decoding: kept, as: UTF8.self) != serverVersion
    }

    public func removeDownload(of path: RemotePath, drive: UUID) {
        try? FileManager.default.removeItem(at: fileFolder(of: path, drive: drive))
    }

    /// Forgets everything kept for a drive, when it's removed from this phone.
    public func remove(drive: UUID) {
        try? FileManager.default.removeItem(at: folder(of: drive))
    }
}
