// Apache 2 license - developer@infinitecontext.com

import CloudCore
import FileProvider
import FileProviderShell
import MountKit
import RemoteEngine
import SyncCore
import UniformTypeIdentifiers

/// Shows one CloudWanderer drive in the Files app, read-only. It runs the same code as the Mac's
/// extension for everything it decides, and refuses every change before reaching the server.
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension {
    private let domain: NSFileProviderDomain
    private let connector: Connector
    private let freshness: Freshness
    private let notes: DriveNotes
    private let tasks = TaskTracker()

    required init(domain: NSFileProviderDomain) {
        // First, before anything reaches the engine: iOS stops this extension at about 20 MB.
        RemoteEngine.useLean()
        Trace.use(subsystem: "com.infinitecontext.CloudWanderer", diagnostics: DriveStore.phoneShared()?.diagnostics)
        self.domain = domain
        let connector = Connector(domainIdentifier: domain.identifier.rawValue, place: .phone)
        let notes = DriveNotes(domainIdentifier: domain.identifier.rawValue)
        self.connector = connector
        self.notes = notes
        freshness = Freshness(connector: connector, domain: domain, notes: notes)
        super.init()
        Footprint.driveStarted()
        Footprint.note("start")
        let temporary = try? NSFileProviderManager(for: domain)?.temporaryDirectoryURL()
        tasks.run {
            DrivePlace.forgetRemovedDrives()
            if let temporary {
                Self.sweep(temporary)
            }
        }
    }

    /// Nothing here changes anything, so stopping loses nothing.
    func invalidate() {
        tasks.invalidate()
        Footprint.driveStopped()
        let freshness = freshness
        Task { await freshness.stop() }
    }

    /// The only real sign a re-import is over: the call that asks for one returns once it's begun.
    func importDidFinish(completionHandler: @escaping () -> Void) {
        let connector = connector
        let handler = Unchecked(completionHandler)
        tasks.run {
            try? await connector.local().store.noteImportFinished()
            handler.value()
        }
    }

    func enumerator(
        for containerItemIdentifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest
    ) throws -> NSFileProviderEnumerator {
        try Identifiers.checkNotTrash(containerItemIdentifier)
        let freshness = freshness
        Task { await freshness.keepFresh() }
        return Enumerator(
            container: containerItemIdentifier, connector: connector,
            beforeChanges: { await freshness.pollIfDue() })
    }

    func item(
        for identifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        let connector = connector
        let handler = Unchecked(completionHandler)
        let task = tasks.run {
            do {
                let drive = try await connector.local()
                guard let item = try drive.store.item(id: Identifiers.syncID(identifier)) else {
                    throw drive.store.missing(identifier.rawValue)
                }
                handler.value(drive.present(item), nil)
            } catch {
                handler.value(nil, Errors.map(error, for: .read, identifier: identifier))
            }
        }
        return cancellable(task, finishes: Progress(totalUnitCount: 1))
    }

    func fetchContents(
        for itemIdentifier: NSFileProviderItemIdentifier,
        version requestedVersion: NSFileProviderItemVersion?,
        request: NSFileProviderRequest,
        completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let connector = connector
        let freshness = freshness
        let notes = notes
        let driveName = domain.displayName
        // Apple asks for the answer to a cancel at once, not when the download notices, and a
        // handler may only be called once.
        let finish = AnswerOnce(completionHandler)
        let isUserRequest = request.isFileViewerRequest
        Trace.log("fetch \(itemIdentifier.rawValue) viewer \(isUserRequest) system \(request.isSystemRequest)")
        let destination = Result { try temporaryFile() }
        let task = tasks.run {
            do {
                let drive = try await connector.open()
                let id = Identifiers.syncID(itemIdentifier)
                let known = try drive.store.item(id: id)
                progress.totalUnitCount = max(known?.size ?? 1, 1)
                let url = try destination.get()
                let saved = try await TransferContext.$isUserRequest.withValue(isUserRequest) {
                    try await TransferContext.$progress.withValue({ progress.completedUnitCount = $0 }) {
                        try await drive.mutations.fetch(id: id, to: url)
                    }
                }
                Footprint.note("download")
                // The server's version is what's here now, so a change kept from another app is gone.
                notes.forget(id: itemIdentifier.rawValue)
                await freshness.note(nil)
                finish.answer(url, drive.present(saved), nil)
            } catch {
                Footprint.note("download failed")
                Trace.failure("download", error, drive: driveName)
                await freshness.note(error)
                finish.answer(nil, nil, Errors.map(error, for: .read, identifier: itemIdentifier))
            }
        }
        progress.cancellationHandler = {
            task.cancel()
            finish.answer(nil, nil, CocoaError(.userCancelled))
        }
        Task {
            await task.value
            progress.completedUnitCount = progress.totalUnitCount
        }
        return progress
    }

    // MARK: Changes, all refused

    // Files offers none of these, because items carry no capability to change. Should one arrive
    // anyway, from an app that saved into a file it opened here, it's refused before connecting.
    // Bytes in hand are never answered "no such item": they're kept here, and the app lists them.

    func createItem(
        basedOn itemTemplate: NSFileProviderItem,
        fields: NSFileProviderItemFields,
        contents url: URL?,
        options: NSFileProviderCreateItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        Trace.log("create refused: \(itemTemplate.filename)")
        if url != nil {
            notes.keep(id: itemTemplate.itemIdentifier.rawValue, name: itemTemplate.filename, isNew: true)
        }
        // Never "leave out": that answer is taken as a delete.
        let holdsData = url != nil || itemTemplate.contentType == .folder
        let answer = Errors.map(
            RemoteError.readOnly, for: .create(isSafelyNew: false, holdsData: holdsData),
            identifier: itemTemplate.itemIdentifier)
        completionHandler(nil, [], false, answer ?? NSFileProviderError(.cannotSynchronize))
        return Progress(totalUnitCount: 0)
    }

    func modifyItem(
        _ item: NSFileProviderItem,
        baseVersion version: NSFileProviderItemVersion,
        changedFields: NSFileProviderItemFields,
        contents newContents: URL?,
        options: NSFileProviderModifyItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        let connector = connector
        let notes = notes
        let handler = Unchecked(completionHandler)
        let identifier = item.itemIdentifier
        let id = Identifiers.syncID(identifier)
        let name = item.filename
        let contents = changedFields.contains(.contents) ? newContents : nil
        let base = Identifiers.baseVersion(of: version)
        let failOnConflict = options.contains(.failOnConflict)
        // Apple calls these working-set signals and asks a provider to keep them: Recents, tags and
        // favourites are built from them. They stay on this iPhone.
        let lastUsed: Date?? = changedFields.contains(.lastUsedDate) ? .some(item.lastUsedDate ?? nil) : .none
        let tags: Data?? = changedFields.contains(.tagData) ? .some(item.tagData ?? nil) : .none
        let rank: Int64?? = changedFields.contains(.favoriteRank)
            ? .some((item.favoriteRank ?? nil)?.int64Value) : .none
        Trace.log("modify \(name) fields \(changedFields.rawValue) contents \(contents != nil)")
        let task = tasks.run {
            do {
                if contents != nil {
                    notes.keep(id: identifier.rawValue, name: name, isNew: false)
                    throw RemoteError.readOnly
                }
                let drive = try await connector.local()
                // Something this drive never had, such as a file another app saved here, is never
                // called gone: that would delete the only copy.
                guard try drive.store.item(id: id) != nil else { throw RemoteError.readOnly }
                let earlier = (try? drive.store.marks(id: id)) ?? ItemMarks()
                let marks = earlier.applying(lastUsed: lastUsed, tags: tags, favoriteRank: rank)
                try? drive.store.setMarks(marks, id: id)
                let outcome = try Mutations.localChange(id: id, baseVersion: base, store: drive.store)
                // The reply names where the item really is. A rename or a move can't reach a
                // read-only server, so iOS puts the item back from this.
                handler.value(drive.present(outcome.item), [], outcome.shouldFetchContent, nil)
            } catch {
                let request = MacAnswer.Request.modify(hasContents: contents != nil, failOnConflict: failOnConflict)
                handler.value(
                    nil, [], false,
                    Errors.map(error, for: request, identifier: identifier) ?? NSFileProviderError(.cannotSynchronize))
            }
        }
        return cancellable(task, finishes: Progress(totalUnitCount: 1))
    }

    func deleteItem(
        identifier: NSFileProviderItemIdentifier,
        baseVersion version: NSFileProviderItemVersion,
        options: NSFileProviderDeleteItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        let connector = connector
        let notes = notes
        let handler = Unchecked(completionHandler)
        let id = Identifiers.syncID(identifier)
        Trace.log("delete \(identifier.rawValue)")
        let task = tasks.run {
            guard let drive = try? await connector.local() else {
                // Without the database it can't be known what this is, so the item comes back.
                handler.value(Errors.map(RemoteError.readOnly, for: .delete, identifier: identifier))
                return
            }
            guard let known = drive.present(id: id) else {
                // Never on the server as far as this drive knows, such as a file another app saved
                // here. It was only ever on this iPhone, so deleting it is the person's to do.
                notes.forget(id: identifier.rawValue)
                handler.value(nil)
                return
            }
            // Still on the server, so the system puts it back as it stands.
            handler.value(Errors.map(RemoteError.readOnly, for: .delete, identifier: identifier, item: known))
        }
        return cancellable(task, finishes: Progress(totalUnitCount: 1))
    }

    // MARK: Helpers

    /// Connects cancelling to the task, and marks the work finished when it ends.
    private func cancellable(_ task: Task<Void, Never>, finishes progress: Progress) -> Progress {
        progress.cancellationHandler = { task.cancel() }
        Task {
            await task.value
            progress.completedUnitCount = progress.totalUnitCount
        }
        return progress
    }

    private func temporaryFile() throws -> URL {
        guard let manager = NSFileProviderManager(for: domain) else {
            throw NSFileProviderError(.providerNotFound)
        }
        return try manager.temporaryDirectoryURL().appendingPathComponent(UUID().uuidString)
    }

    /// Removes what a download left in the temporary folder when iOS stopped this extension part
    /// way. Apple leaves that to the extension. Anything from the last hour may still be in use.
    private static func sweep(_ folder: URL) {
        let files = FileManager.default
        let cutoff = Date().addingTimeInterval(-3600)
        guard let names = try? files.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }
        for file in names {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff {
                try? files.removeItem(at: file)
            }
        }
    }
}

/// Calls a completion handler once, whichever comes first: the result, or a cancel.
final class AnswerOnce<A, B, C>: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((A, B, C) -> Void)?

    init(_ handler: @escaping (A, B, C) -> Void) {
        self.handler = handler
    }

    func answer(_ a: A, _ b: B, _ c: C) {
        let once = lock.withLock {
            let pending = handler
            handler = nil
            return pending
        }
        once?(a, b, c)
    }
}

extension DrivePlace {
    /// The iPhone's drives are in the folder the app shares with this extension. Their databases
    /// are in this extension's own folder: the app never opens them, so a suspended app can't hold
    /// a lock on one, which iOS punishes by stopping it.
    static let phone = DrivePlace(
        drives: {
            guard let store = DriveStore.phoneShared() else { throw DriveStore.StoreError.noSharedFolder }
            return store
        },
        database: { _, id in
            let own = ownFolder
            return (try own.databaseURL(for: id), try own.backupURL(for: id))
        },
        device: { _ in nil },
        isAlwaysReadOnly: true,
        serves: { FilesLocations.canShow($0) })

    /// Where this extension keeps its databases. Only paths are used from it.
    private static var ownFolder: DriveStore {
        DriveStore(directory: URL.applicationSupportDirectory)
    }

    /// Deletes the databases of drives the app no longer has. Each one is only a copy of what the
    /// server lists, so nothing is lost. A list that can't be read, or was never saved, says
    /// nothing about any drive, so then nothing goes.
    static func forgetRemovedDrives() {
        guard let saved = DriveStore.phoneShared(), let drives = try? saved.savedConnections() else { return }
        let kept = Set(drives.map(\.id))
        let folder = URL.applicationSupportDirectory.appendingPathComponent("Drives")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        for name in names where name.hasSuffix(".sqlite") {
            guard let id = UUID(uuidString: String(name.dropLast(".sqlite".count))), !kept.contains(id) else {
                continue
            }
            try? ownFolder.deleteDatabase(for: id)
        }
    }
}
