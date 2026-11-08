// Apache 2 license - developer@infinitecontext.com

import CloudCore
import FileProvider
import MountKit
import SyncCore

/// Where the next page of an enumeration starts. It holds the folder's generation and the
/// database's epoch, so a page can't continue across a change to the folder or a recovery.
private struct PageCursor {
    var generation: Int64
    var epoch: String
    var lastID: String

    init?(_ page: NSFileProviderPage) {
        let parts = String(decoding: page.rawValue, as: UTF8.self).split(separator: "|", maxSplits: 3)
        guard parts.count == 4, parts[0] == "cm", let generation = Int64(parts[1]) else { return nil }
        self.generation = generation
        epoch = String(parts[2])
        lastID = String(parts[3])
    }

    static func page(generation: Int64, epoch: String, lastID: String) -> NSFileProviderPage {
        NSFileProviderPage(Data("cm|\(generation)|\(epoch)|\(lastID)".utf8))
    }
}

public final class Enumerator: NSObject, NSFileProviderEnumerator {
    private let container: NSFileProviderItemIdentifier
    private let connector: Connector
    private let beforeChanges: (@Sendable () async -> Void)?
    private let tasks = TaskTracker()

    /// Used when macOS doesn't suggest a size. It enforces at most 100 times its suggestion.
    private static let defaultPageSize = 200

    /// - Parameter beforeChanges: Runs before changes are read. The Mac's app polls, so it has
    ///   none; on the iPhone nothing else checks the server while Files asks.
    public init(
        container: NSFileProviderItemIdentifier, connector: Connector,
        beforeChanges: (@Sendable () async -> Void)? = nil
    ) {
        self.container = container
        self.connector = connector
        self.beforeChanges = beforeChanges
    }

    public func invalidate() {
        tasks.invalidate()
    }

    /// macOS takes whatever a listing leaves out as deleted, so a database that's still reading
    /// the server back mustn't list anything yet.
    private static func checkSettled(_ drive: LocalDrive) throws {
        if try drive.store.needsRebuild() {
            throw SyncError.recovering
        }
    }

    public func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        let size = max(observer.suggestedPageSize ?? Self.defaultPageSize, 1)
        let box = Unchecked(observer)
        let container = container
        let connector = connector
        tasks.run {
            let observer = box.value
            do {
                // What's known locally needs no server, so a listing works during an outage.
                let local = try await connector.local()
                try Self.checkSettled(local)
                let cursor = PageCursor(page)
                let epoch = try local.store.currentAnchor().epoch
                if let cursor, cursor.epoch != epoch {
                    throw NSFileProviderError(.pageExpired)
                }
                let items: [SyncItem]
                var generation: Int64 = 0
                if container == .workingSet {
                    if cursor == nil, let drive = try? await connector.open() {
                        // The root may never be listed on its own, so a new drive starts here.
                        _ = try? await drive.syncer.refresh(folderID: SyncItem.rootID)
                    }
                    items = try local.store.allItems(after: cursor?.lastID, limit: size)
                } else if let document = try local.store.item(id: Identifiers.syncID(container)),
                          document.kind == .file {
                    // An app has this document open, and macOS follows it this way. A server can't
                    // list a file, and its not-found would have macOS drop the open document.
                    items = cursor == nil ? [document] : []
                } else {
                    let id = Identifiers.syncID(container)
                    if cursor == nil {
                        try? local.store.markOpened(id: id)
                        do {
                            let drive = try await connector.open()
                            try await drive.syncer.refresh(folderID: id)
                        } catch {
                            let knowsItems = try !local.store.children(of: id, after: nil, limit: 1).isEmpty
                            guard MacAnswer.listingShowsWhatsKnown(after: error, knowsItems: knowsItems) else {
                                throw error
                            }
                        }
                    }
                    generation = try local.store.item(id: id)?.generation ?? 0
                    if let cursor, cursor.generation != generation {
                        throw NSFileProviderError(.pageExpired)
                    }
                    items = try local.store.children(of: id, after: cursor?.lastID, limit: size)
                }
                Trace.log("list \(container.rawValue): \(items.count) items")
                observer.didEnumerate(items.map(local.presenter()))
                let next = items.count == size ? items.last.map {
                    PageCursor.page(generation: generation, epoch: epoch, lastID: $0.id)
                } : nil
                observer.finishEnumerating(upTo: next)
            } catch {
                observer.finishEnumeratingWithError(
                    Errors.map(error, for: .read, identifier: container) ?? NSFileProviderError(.cannotSynchronize))
            }
        }
    }

    public func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        let size = max(observer.suggestedBatchSize ?? Self.defaultPageSize, 1)
        let box = Unchecked(observer)
        let container = container
        let connector = connector
        let beforeChanges = beforeChanges
        tasks.run {
            let observer = box.value
            do {
                // Every change is delivered through the working set.
                guard container == .workingSet else {
                    observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
                    return
                }
                await beforeChanges?()
                let drive = try await connector.local()
                try Self.checkSettled(drive)
                guard let start = SyncAnchor(encoded: anchor.rawValue) else {
                    throw SyncError.anchorExpired
                }
                let changes = try drive.store.changes(since: start, limit: size)
                Trace.log(
                    "changes from \(start.sequence): updated \(changes.updated.map(\.name)) "
                        + "deleted \(changes.deleted.count) to \(changes.anchor.sequence)")
                if !changes.updated.isEmpty {
                    observer.didUpdate(changes.updated.map(drive.presenter()))
                }
                if !changes.deleted.isEmpty {
                    observer.didDeleteItems(withIdentifiers: changes.deleted.map(Identifiers.identifier))
                }
                observer.finishEnumeratingChanges(
                    upTo: NSFileProviderSyncAnchor(changes.anchor.encoded), moreComing: changes.moreComing)
            } catch {
                observer.finishEnumeratingWithError(
                    Errors.map(error, for: .read, identifier: container) ?? NSFileProviderError(.cannotSynchronize))
            }
        }
    }

    public func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        let box = Unchecked(completionHandler)
        let connector = connector
        tasks.run {
            let drive = try? await connector.local()
            let anchor = try? drive?.store.currentAnchor()
            box.value(anchor.map { NSFileProviderSyncAnchor($0.encoded) })
        }
    }
}
