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

    /// Keeps a finished download, replacing any older one. The new copy is made complete beside
    /// the old one and swapped in, because this may be the only copy within reach: if anything
    /// fails, the old one is still there.
    /// - Parameter version: The version of these bytes, so a newer one can be noticed later.
    @discardableResult
    public func keep(
        _ finished: URL, as path: RemotePath, drive: UUID, version: String? = nil, now: Date = Date()
    ) throws -> URL {
        let files = FileManager.default
        let target = fileFolder(of: path, drive: drive)
        let fresh = target.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try makeFolder(fresh)
        do {
            try files.moveItem(at: finished, to: fresh.appendingPathComponent(path.name))
            try version.map {
                try Data($0.utf8).write(to: fresh.appendingPathComponent(Self.versionRecord), options: .atomic)
            }
            try Self.recordUse(in: fresh, at: now)
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

    // MARK: Keep-times

    /// When a kept file was last used, beside it. `.cm-` names are reserved on every drive.
    private static let usedRecord = ".cm-used"

    private static func recordUse(in folder: URL, at date: Date) throws {
        try Data(String(date.timeIntervalSince1970).utf8)
            .write(to: folder.appendingPathComponent(usedRecord), options: .atomic)
    }

    private static func lastUse(in folder: URL) -> Date? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(usedRecord)),
              let seconds = TimeInterval(String(decoding: data, as: UTF8.self))
        else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// Restarts a kept file's clock, when it's played, shared or exported.
    public func touch(_ path: RemotePath, drive: UUID, now: Date = Date()) {
        guard download(of: path, drive: drive) != nil else { return }
        try? Self.recordUse(in: fileFolder(of: path, drive: drive), at: now)
    }

    /// Removes kept files unused for longer than their keep-time: `mediaAfter` for films and
    /// music (`MediaFiles`), `otherAfter` for the rest. A file kept before keep-times existed has
    /// no record, and gets one now, so nothing already on the phone vanishes on the first pass.
    /// - Parameter sparing: Files in use now, such as the one playing, which stay whatever their age.
    /// - Returns: How many files were removed.
    @discardableResult
    public func removeExpired(
        mediaAfter: TimeInterval, otherAfter: TimeInterval, sparing: Set<URL> = [], now: Date = Date()
    ) -> Int {
        let files = FileManager.default
        let spared = Set(sparing.map(\.standardizedFileURL.path))
        var removed = 0
        let drives = (try? files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for drive in drives {
            let kept = drive.appendingPathComponent("files")
            // Kept files sit under a 64-letter hash. Anything else is cleared by `clearAbandoned`.
            for folder in (try? files.contentsOfDirectory(at: kept, includingPropertiesForKeys: nil)) ?? []
            where folder.lastPathComponent.count == 64 {
                let names = ((try? files.contentsOfDirectory(atPath: folder.path)) ?? [])
                    .filter { !$0.hasPrefix(".cm-") }
                guard let name = names.first else { continue }
                if spared.contains(folder.appendingPathComponent(name).standardizedFileURL.path) { continue }
                guard let used = Self.lastUse(in: folder) else {
                    try? Self.recordUse(in: folder, at: now)
                    continue
                }
                let limit = MediaFiles.isMedia(name) ? mediaAfter : otherAfter
                if now.timeIntervalSince(used) >= limit, (try? files.removeItem(at: folder)) != nil {
                    removed += 1
                }
            }
        }
        return removed
    }

    public func removeDownload(of path: RemotePath, drive: UUID) {
        try? FileManager.default.removeItem(at: fileFolder(of: path, drive: drive))
    }

    /// Forgets everything kept for a drive, when it's removed from this phone.
    public func remove(drive: UUID) {
        try? FileManager.default.removeItem(at: folder(of: drive))
    }
}
