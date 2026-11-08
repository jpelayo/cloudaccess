// Apache 2 license - developer@infinitecontext.com

import CloudCore
import FileProvider
import FileProviderShell
import ImageIO
import MountKit
import RemoteEngine
import SyncCore
import UniformTypeIdentifiers

/// Serves one drive to macOS. Identity and change tracking come from `SyncStore`.
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension, NSFileProviderThumbnailing {
    private let domain: NSFileProviderDomain
    private let connector: Connector
    private let tasks = TaskTracker()

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        connector = Connector(domainIdentifier: domain.identifier.rawValue, place: .mac)
        super.init()
    }

    /// macOS replays anything unfinished, so stopping here loses nothing.
    func invalidate() {
        tasks.invalidate()
    }

    /// The only real sign a re-import is over: the call that asks for one returns once it's begun.
    /// From here on, an item the database doesn't know really is gone.
    func importDidFinish(completionHandler: @escaping () -> Void) {
        let connector = connector
        let handler = Unchecked(completionHandler)
        Trace.log("import finished")
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
        return Enumerator(container: containerItemIdentifier, connector: connector)
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
        let driveName = domain.displayName
        let handler = Unchecked(completionHandler)
        let isUserRequest = request.isFileViewerRequest
        Trace.log(
            "fetch \(itemIdentifier.rawValue) viewer \(isUserRequest) system \(request.isSystemRequest) "
                + "by \(request.requestingExecutable?.lastPathComponent ?? "unknown")")
        let destination = Result { try temporaryFile() }
        let task = tasks.run {
            do {
                let drive = try await connector.open()
                let id = Identifiers.syncID(itemIdentifier)
                let known = try drive.store.item(id: id)
                progress.totalUnitCount = max(known?.size ?? 1, 1)
                let url = try destination.get()
                let report = TransferReporter(
                    store: drive.store, name: known?.name ?? itemIdentifier.rawValue, direction: .download,
                    total: progress.totalUnitCount)
                defer { report.finish() }
                Trace.arrival("fetch", name: known?.name ?? "", type: nil, options: 0, contents: nil)
                let saved = try await TransferContext.$isUserRequest.withValue(isUserRequest) {
                    try await TransferContext.$progress.withValue({
                        progress.completedUnitCount = $0
                        report.update($0)
                    }) {
                        try await drive.mutations.fetch(id: id, to: url)
                    }
                }
                handler.value(url, drive.present(saved), nil)
            } catch {
                Trace.failure("download", error, drive: driveName)
                handler.value(nil, nil, Errors.map(error, for: .read, identifier: itemIdentifier))
            }
        }
        return cancellable(task, finishes: progress)
    }

    func createItem(
        basedOn itemTemplate: NSFileProviderItem,
        fields: NSFileProviderItemFields,
        contents url: URL?,
        options: NSFileProviderCreateItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        let name = itemTemplate.filename
        Trace.log("create \(name) fields \(fields.rawValue) options \(options.rawValue)")
        Trace.arrival(
            "create", name: name, type: itemTemplate.contentType, options: options.rawValue, contents: url)
        // Symlinks have no place in the item model, so they stay local like housekeeping files.
        let isSymlink = itemTemplate.contentType == .symbolicLink
        let staysLocal = isSymlink || Mutations.isHousekeeping(name)
        let hasOptions = !options.isEmpty
        let connector = connector
        let driveName = domain.displayName
        let handler = Unchecked(completionHandler)
        let parentID = Identifiers.syncID(itemTemplate.parentItemIdentifier)
        let isFolder = itemTemplate.contentType == .folder
        let templateIdentifier = itemTemplate.itemIdentifier
        let templateID = Identifiers.syncID(templateIdentifier)
        let mayAlreadyExist = options.contains(.mayAlreadyExist)
        let details = Self.details(of: itemTemplate, name: name)
        let progress = Self.uploadProgress(for: url)
        let task = tasks.run {
            do {
                // Before connecting, so macOS's retries of a held file never reach the server.
                let id = SyncFailure.unsentID(name: name, parentID: parentID)
                let local = try await connector.local()
                if staysLocal {
                    let isNew = Mutations.isSafelyNew(
                        id: templateID, name: name, parentID: parentID, hasOptions: hasOptions, store: local.store)
                    if isNew {
                        handler.value(nil, [], false, NSFileProviderError(.excludedFromSync))
                        return
                    }
                    let drive = try await connector.open()
                    switch await drive.mutations.settleLocalOnly(
                        id: templateID, name: name, parentID: parentID, mayAdopt: !isSymlink) {
                    case .adopted(let item):
                        handler.value(drive.present(item), [], false, nil)
                    case .leaveOut:
                        handler.value(nil, [], false, NSFileProviderError(.excludedFromSync))
                    case .tryLater:
                        handler.value(nil, [], false, NSFileProviderError(.cannotSynchronize))
                    }
                    return
                }
                try local.store.checkNotHeld(id: id)
                let drive = try await connector.open(forFile: id, named: name, local: local)
                let report = url.map { _ in
                    TransferReporter(
                        store: drive.store, name: name, direction: .upload, total: progress.totalUnitCount)
                }
                defer { report?.finish() }
                let saved = try await TransferContext.$progress.withValue({
                    progress.completedUnitCount = $0
                    report?.update($0)
                }) {
                    try await drive.mutations.create(
                        name: name, parentID: parentID, isFolder: isFolder, contents: url,
                        mayAlreadyExist: mayAlreadyExist, details: details)
                }
                handler.value(drive.present(saved), [], false, nil)
            } catch {
                Trace.log("create failed: \(error)")
                Trace.failure("create", error, drive: driveName)
                let store = try? await connector.local().store
                let isNew = store.map {
                    Mutations.isSafelyNew(
                        id: templateID, name: name, parentID: parentID, hasOptions: hasOptions, store: $0)
                } ?? false
                let answer = Errors.map(error, for: .create(isSafelyNew: isNew), identifier: templateIdentifier)
                handler.value(nil, [], false, answer ?? NSFileProviderError(.cannotSynchronize))
            }
        }
        return cancellable(task, finishes: progress)
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
        let driveName = domain.displayName
        let handler = Unchecked(completionHandler)
        let identifier = item.itemIdentifier
        let id = Identifiers.syncID(identifier)
        let filename = item.filename
        let moved = changedFields.contains(.filename) || changedFields.contains(.parentItemIdentifier)
        let shownAt = (parentID: Identifiers.syncID(item.parentItemIdentifier), name: filename)
        let location = moved ? shownAt : nil
        let contents = changedFields.contains(.contents) ? newContents : nil
        let base = Identifiers.baseVersion(of: version)
        let failOnConflict = options.contains(.failOnConflict)
        let signal = Unchecked(signalChanges)
        let progress = Self.uploadProgress(for: contents)
        Trace.log("modify \(filename) fields \(changedFields.rawValue) contents \(contents != nil)")
        Trace.arrival("modify", name: filename, type: item.contentType, options: options.rawValue, contents: contents)
        let used = changedFields.contains(.lastUsedDate) ? item.lastUsedDate ?? nil : nil
        let details = Self.details(of: item, name: filename)
        let task = tasks.run {
            do {
                if location == nil, contents == nil {
                    // Nothing here needs the server, so it mustn't wait for one.
                    let drive = try await connector.local()
                    if let used {
                        try? drive.store.noteUsed(id: id, at: used)
                    }
                    let outcome = try Mutations.localChange(id: id, baseVersion: base, store: drive.store)
                    handler.value(drive.present(outcome.item), [], outcome.shouldFetchContent, nil)
                    return
                }
                let local = try await connector.local()
                try Mutations.checkMayTry(id: id, newName: location?.name, store: local.store)
                let drive = try await connector.open(forFile: id, named: filename, local: local)
                let report = contents.map { _ in
                    TransferReporter(
                        store: drive.store, name: filename, direction: .upload,
                        total: progress.totalUnitCount)
                }
                defer { report?.finish() }
                let outcome = try await TransferContext.$progress.withValue({
                    progress.completedUnitCount = $0
                    report?.update($0)
                }) {
                    try await drive.mutations.modify(
                        id: id, baseVersion: base, newLocation: location, contents: contents,
                        failOnConflict: failOnConflict, shownAt: shownAt, details: details)
                }
                handler.value(drive.present(outcome.item), [], outcome.shouldFetchContent, nil)
                if outcome.changedOtherItems {
                    signal.value()
                }
            } catch {
                Trace.log("modify failed: \(error)")
                Trace.failure("modify", error, drive: driveName)
                let request = MacAnswer.Request.modify(hasContents: contents != nil, failOnConflict: failOnConflict)
                handler.value(
                    nil, [], false, Errors.map(error, for: request, identifier: identifier)
                        ?? NSFileProviderError(.cannotSynchronize))
                // The item that has the name may be new to macOS, and it's in the change list now.
                if case .nameTaken = MacAnswer.to(request, failingWith: error) {
                    signal.value()
                }
            }
        }
        return cancellable(task, finishes: progress)
    }

    func deleteItem(
        identifier: NSFileProviderItemIdentifier,
        baseVersion version: NSFileProviderItemVersion,
        options: NSFileProviderDeleteItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        let connector = connector
        let driveName = domain.displayName
        let handler = Unchecked(completionHandler)
        let id = Identifiers.syncID(identifier)
        let base = Identifiers.baseVersion(of: version)
        Trace.log("delete \(id)")
        let task = tasks.run {
            do {
                let drive = try await connector.open()
                try await drive.mutations.delete(id: id, baseVersion: base)
                handler.value(nil)
            } catch {
                // A refused delete carries the item, so macOS can put it back as it stands.
                let known = (try? await connector.local())?.present(id: id)
                // Nil means it was already gone, which isn't a failure.
                let answer = Errors.map(error, for: .delete, identifier: identifier, item: known)
                if answer != nil {
                    Trace.log("delete failed: \(error)")
                    Trace.failure("delete", error, drive: driveName)
                }
                handler.value(answer)
            }
        }
        return cancellable(task, finishes: Progress(totalUnitCount: 1))
    }

    // MARK: Thumbnails

    /// Thumbnails download the file, so only images under the drive's limit get one.
    func fetchThumbnails(
        for itemIdentifiers: [NSFileProviderItemIdentifier],
        requestedSize size: CGSize,
        perThumbnailCompletionHandler: @escaping (NSFileProviderItemIdentifier, Data?, Error?) -> Void,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        let connector = connector
        let each = Unchecked(perThumbnailCompletionHandler)
        let finish = Unchecked(completionHandler)
        let folder = Result { try temporaryFile() }
        let task = tasks.run {
            guard let drive = try? await connector.open(), let local = try? folder.get() else {
                finish.value(nil)
                return
            }
            defer { try? FileManager.default.removeItem(at: local) }
            for identifier in itemIdentifiers {
                if Task.isCancelled { break }
                let image = await Self.thumbnail(
                    of: Identifiers.syncID(identifier), drive: drive, size: size, using: local)
                each.value(identifier, image, nil)
            }
            finish.value(nil)
        }
        return cancellable(task, finishes: Progress(totalUnitCount: Int64(itemIdentifiers.count)))
    }

    private static func thumbnail(
        of id: String, drive: OpenDrive, size: CGSize, using local: URL
    ) async -> Data? {
        guard let limit = drive.settings().thumbnailLimit,
              let item = try? drive.store.item(id: id), item.kind == .file,
              let bytes = item.size, bytes <= limit,
              UTType(filenameExtension: (item.name as NSString).pathExtension)?.conforms(to: .image) == true,
              let path = try? drive.store.path(of: id),
              (try? await drive.engine.download(path, to: local)) != nil,
              let source = CGImageSourceCreateWithURL(local as CFURL, nil)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(size.width, size.height),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }

    private func signalChanges() {
        NSFileProviderManager(for: domain)?.signalEnumerator(for: .workingSet) { _ in }
    }

    /// What macOS says about a file, which servers that keep file details store beside it. Read
    /// before the work starts, because the item macOS hands over isn't safe to keep.
    private static func details(of item: NSFileProviderItem, name: String) -> FileDetails {
        var bundleType: String?
        if FlattenedPackage.isFlattened(name), let type = item.contentType, type != .item, type != .data {
            bundleType = type.identifier
        }
        return FileDetails(
            modified: item.contentModificationDate ?? nil, created: item.creationDate ?? nil, bundleType: bundleType)
    }

    private static func uploadProgress(for url: URL?) -> Progress {
        let size = url.flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize } ?? 1
        return Progress(totalUnitCount: Int64(max(size, 1)))
    }

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
}

extension DrivePlace {
    /// The Mac's drives are in the folder the app shares with this extension, and this Mac signs
    /// its staging files and conflict copies with its own name.
    static let mac = DrivePlace(
        drives: { try DriveStore.shared() },
        database: { saved, id in (try saved.databaseURL(for: id), try saved.backupURL(for: id)) },
        device: { saved in DeviceInfo(id: try saved.deviceID(), name: Host.current().localizedName ?? "Mac") },
        isAlwaysReadOnly: false,
        serves: { _ in true })
}
