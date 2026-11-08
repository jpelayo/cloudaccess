// Apache 2 license - developer@infinitecontext.com

import CloudCore
import CryptoKit
import Foundation

/// A simulated server held in memory, which can be told to fail on demand.
public actor FakeRemote: RemoteBackend {
    private struct Entry {
        var kind: RemoteItem.Kind
        var content = Data()
        var modified: Date
        var revision = 1
        /// File details, as the engine keeps them beside a file. Apache keeps them when another
        /// tool writes over the file, so they stay, and the revision says whether they still describe it.
        var details: FileDetails?
        var detailsRevision = 0
    }

    private var entries: [RemotePath: Entry] = [:]
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)
    private var failure: RemoteError?
    private var longestName: Int?
    /// How many uploads began, whatever became of them.
    public private(set) var stagesStarted = 0
    private var hiddenFromListings = Set<RemotePath>()
    private var responsesToLose = 0
    private var reportsVersions = true
    private var changeDuringDownload: (path: RemotePath, content: Data)?
    private var duringNextStage: (@Sendable () async -> Void)?
    private var stagedFiles: [String: Data] = [:]
    private var duringNextCommit: (@Sendable () async -> Void)?
    private var downloadsToShorten = 0
    private var briefAbsences = Set<RemotePath>()
    public private(set) var listingCount = 0
    private var keepsDetails = true

    /// Errors here are the ones the real engine gives in the same case. A test that passes because
    /// this one says something the engine never says proves nothing about the app.
    public init() {}

    // MARK: Test controls

    /// The next look at this path finds nothing, once. Apache does this in the middle of a save
    /// that replaces a file, because it removes the old one before moving the new one in.
    public func goMissingOnce(_ path: RemotePath) {
        briefAbsences.insert(path)
    }

    private func checkPresent(_ path: RemotePath) throws {
        if briefAbsences.remove(path) != nil {
            throw RemoteError.notFound(path)
        }
    }

    /// Like a server that gives no ETags.
    public func stopReportingVersions() {
        reportsVersions = false
    }

    /// The next writes reach the server, but their responses never arrive.
    public func loseResponses(_ count: Int = 1) {
        responsesToLose = count
    }

    /// A peer replaces this file while the next download is running.
    public func changeDuringNextDownload(_ path: RemotePath, content: Data) {
        changeDuringDownload = (path, content)
    }

    /// Runs while the next upload is under way, for what can happen during a long one.
    public func duringNextStage(_ action: @escaping @Sendable () async -> Void) {
        duringNextStage = action
    }

    /// Runs just before the next commit, after the save has worked out where it's going.
    public func duringNextCommit(_ action: @escaping @Sendable () async -> Void) {
        duringNextCommit = action
    }

    /// Sends less of the next few downloads than the listing says, with no error.
    public func shortenDownloads(_ count: Int = 1) {
        downloadsToShorten = count
    }

    /// How many staged uploads are waiting, which is none once every save has finished.
    public var stagedCount: Int {
        stagedFiles.count
    }

    private func checkResponse() throws {
        if responsesToLose > 0 {
            responsesToLose -= 1
            throw RemoteError.unreachable("The response was lost")
        }
    }

    /// Refuses names longer than this, as an encrypted drive does.
    public func limitNames(to bytes: Int?) {
        longestName = bytes
    }

    /// Makes every request fail until cleared.
    public func fail(with error: RemoteError?) {
        failure = error
    }

    /// Leaves a path out of listings while direct checks still find it, like a truncated listing.
    public func hideFromListings(_ path: RemotePath, hidden: Bool = true) {
        if hidden {
            hiddenFromListings.insert(path)
        } else {
            hiddenFromListings.remove(path)
        }
    }

    /// A change made by another device, or by another tool. Details stay, as on Apache, but they no
    /// longer describe the new bytes.
    public func put(_ path: RemotePath, content: Data) {
        ensureParents(of: path)
        clock.addTimeInterval(1)
        let old = entries[path]
        let revision = (old?.revision ?? 0) + 1
        entries[path] = Entry(
            kind: .file, content: content, modified: clock, revision: revision,
            details: old?.details, detailsRevision: old?.detailsRevision ?? 0)
    }

    /// Stops keeping file details, like a server that refuses properties.
    public func refuseDetails() {
        keepsDetails = false
    }

    /// Gives a file details without changing its bytes, as a replayed save does once its file is
    /// already in place.
    public func addDetails(_ path: RemotePath, _ details: FileDetails) {
        describe(path, with: details)
    }

    /// Records details as a save would, carrying the creation date already recorded forward.
    private func describe(_ path: RemotePath, with details: FileDetails) {
        guard keepsDetails, var entry = entries[path],
              details.modified != nil || details.created != nil || details.bundleType != nil
        else { return }
        var kept = details
        kept.created = entry.details?.created ?? details.created
        entry.details = kept
        entry.detailsRevision = entry.revision
        entries[path] = entry
    }

    public func makeFolder(_ path: RemotePath) {
        ensureParents(of: path)
        clock.addTimeInterval(1)
        entries[path] = Entry(kind: .directory, modified: clock)
    }

    public func remove(_ path: RemotePath) {
        for key in entries.keys where key == path || key.components.starts(with: path.components) {
            entries[key] = nil
        }
    }

    public func rename(_ source: RemotePath, to destination: RemotePath) {
        for (key, entry) in entries where key == source || key.components.starts(with: source.components) {
            let tail = key.components.dropFirst(source.components.count).joined(separator: "/")
            let moved = RemotePath(destination.components.joined(separator: "/") + "/" + tail) ?? destination
            entries[key] = nil
            entries[moved] = entry
        }
    }

    public func content(at path: RemotePath) -> Data? {
        entries[path]?.content
    }

    private func ensureParents(of path: RemotePath) {
        var current = path.parent
        while let folder = current, !folder.isRoot {
            if entries[folder] == nil {
                entries[folder] = Entry(kind: .directory, modified: clock)
            }
            current = folder.parent
        }
    }

    private func check() throws {
        if let failure { throw failure }
    }

    private func item(_ path: RemotePath, _ entry: Entry) -> RemoteItem {
        let describesContent = entry.details != nil && entry.detailsRevision == entry.revision && entry.kind == .file
        return RemoteItem(
            path: path,
            kind: entry.kind,
            size: entry.kind == .file ? Int64(entry.content.count) : nil,
            modified: entry.modified,
            versionID: entry.kind == .file && reportsVersions ? "\"\(entry.revision)\"" : nil,
            ownModified: describesContent ? entry.details?.modified : nil,
            created: entry.details?.created,
            checksum: describesContent ? Self.checksum(entry.content) : nil,
            bundleType: describesContent ? entry.details?.bundleType : nil)
    }

    private static func checksum(_ content: Data) -> String {
        SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: RemoteBackend

    public func checkHealth() async throws {
        try check()
    }

    public func reportsVersions() async throws -> Bool {
        try check()
        return reportsVersions
    }

    public func item(at path: RemotePath) async throws -> RemoteItem {
        try check()
        try checkPresent(path)
        if path.isRoot { return RemoteItem(path: .root, kind: .directory) }
        guard let entry = entries[path] else { throw RemoteError.notFound(path) }
        return item(path, entry)
    }

    public func list(_ path: RemotePath) async throws -> [RemoteItem] {
        try check()
        try checkPresent(path)
        listingCount += 1
        if !path.isRoot && entries[path] == nil { throw RemoteError.notFound(path) }
        return entries
            .filter { $0.key.parent == path && !hiddenFromListings.contains($0.key) }
            .map { item($0.key, $0.value) }
            .sorted { $0.path.description < $1.path.description }
    }

    public func download(_ path: RemotePath, to destination: URL) async throws {
        try check()
        guard let entry = entries[path] else { throw RemoteError.notFound(path) }
        if downloadsToShorten > 0 {
            downloadsToShorten -= 1
            try entry.content.prefix(1).write(to: destination)
        } else {
            try entry.content.write(to: destination)
        }
        if let change = changeDuringDownload, change.path == path {
            changeDuringDownload = nil
            put(change.path, content: change.content)
        }
    }

    public func read(_ path: RemotePath, offset: Int64, length: Int64, to destination: URL) async throws {
        try check()
        guard let entry = entries[path] else { throw RemoteError.notFound(path) }
        let start = Int(offset)
        let end = min(start + Int(length), entry.content.count)
        try entry.content.subdata(in: start..<end).write(to: destination)
    }

    @discardableResult
    public func upload(from source: URL, to path: RemotePath) async throws -> RemoteItem {
        try check()
        put(path, content: try Data(contentsOf: source))
        guard let entry = entries[path] else { throw RemoteError.notFound(path) }
        return item(path, entry)
    }

    public func stage(from source: URL) async throws -> StagedUpload {
        stagesStarted += 1
        try check()
        let content = try Data(contentsOf: source)
        if let action = duringNextStage {
            duringNextStage = nil
            await action()
        }
        let token = UUID().uuidString
        stagedFiles[token] = content
        return StagedUpload(token: token)
    }

    public func discard(_ staged: StagedUpload) {
        stagedFiles[staged.token] = nil
    }

    public func checkName(_ path: RemotePath) async throws {
        if let longestName, path.name.utf8.count > longestName {
            throw RemoteError.nameTooLong(path)
        }
    }

    @discardableResult
    public func commit(
        _ staged: StagedUpload, source: URL, to path: RemotePath, baseVersion: String?, failOnConflict: Bool
    ) async throws -> SaveResult {
        try await commit(
            staged, source: source, to: path, baseVersion: baseVersion, failOnConflict: failOnConflict,
            details: FileDetails())
    }

    @discardableResult
    public func commit(
        _ staged: StagedUpload, source: URL, to path: RemotePath, baseVersion: String?, failOnConflict: Bool,
        details: FileDetails
    ) async throws -> SaveResult {
        if let action = duringNextCommit {
            duringNextCommit = nil
            await action()
        }
        try check()
        guard let content = stagedFiles.removeValue(forKey: staged.token) else {
            throw RemoteError.failed(path, "Nothing staged")
        }
        if let entry = entries[path] {
            let current = item(path, entry).versionID
            if baseVersion == nil || current == nil || current != baseVersion {
                // A replay finds its own earlier save, which isn't a conflict.
                if entry.content == content {
                    return SaveResult(item: item(path, entry))
                }
                if failOnConflict {
                    throw RemoteError.versionMismatch(path)
                }
                guard let copy = path.parent?.appending("\(path.name) (conflict)") else {
                    throw RemoteError.failed(path, "No parent")
                }
                put(copy, content: content)
                describe(copy, with: details)
                try checkResponse()
                return SaveResult(item: item(path, entry), conflictCopy: copy)
            }
        }
        put(path, content: content)
        describe(path, with: details)
        guard let entry = entries[path] else { throw RemoteError.notFound(path) }
        try checkResponse()
        return SaveResult(item: item(path, entry))
    }

    public func createDirectory(_ path: RemotePath) async throws {
        try await createDirectory(path, created: nil)
    }

    /// A folder another device made first keeps its own creation date, as on the server.
    public func createDirectory(_ path: RemotePath, created: Date?) async throws {
        try check()
        let earlier = entries[path]
        makeFolder(path)
        if let kept = earlier?.details {
            entries[path]?.details = kept
        } else if earlier == nil, keepsDetails, let created {
            entries[path]?.details = FileDetails(created: created)
        }
    }

    @discardableResult
    public func move(
        from source: RemotePath, to destination: RemotePath, baseVersion: String?
    ) async throws -> RemoteItem {
        try check()
        guard entries[source] != nil else {
            // A replay only recognises its own result, by its version.
            if let moved = entries[destination] {
                let found = item(destination, moved)
                if moved.kind == .directory || (baseVersion != nil && found.versionID == baseVersion) {
                    return found
                }
            }
            throw RemoteError.notFound(source)
        }
        guard entries[destination] == nil else { throw RemoteError.alreadyExists(destination) }
        rename(source, to: destination)
        try checkResponse()
        return try await item(at: destination)
    }

    public func delete(_ path: RemotePath) async throws {
        try check()
        guard entries[path] != nil else { throw RemoteError.notFound(path) }
        remove(path)
    }

    public func trash(_ path: RemotePath, baseVersion: String?) async throws {
        try check()
        guard let entry = entries[path] else { return }
        if entry.kind == .file, item(path, entry).versionID != baseVersion {
            throw RemoteError.versionMismatch(path)
        }
        remove(path)
        try checkResponse()
    }
}
