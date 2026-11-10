// Apache 2 license - developer@infinitecontext.com

import CloudCore
import Foundation

/// Compares a drive's folders with the server and updates the store.
public struct Syncer: Sendable {
    /// How the false-delete guards behave.
    public struct Guards: Sendable {
        /// Direct not-found checks needed before an item is removed.
        public var passes = 2
        /// Extra pass needed when a folder loses this many items at once.
        public var massCount = 20
        /// Or this share of its items.
        public var massShare = 0.2
        /// Passes must span at least this long.
        public var minimumSpan: TimeInterval = 60

        public init() {}
    }

    private let store: SyncStore
    private let backend: any RemoteBackend
    private let guards: Guards

    public init(store: SyncStore, backend: any RemoteBackend, guards: Guards = Guards()) {
        self.store = store
        self.backend = backend
        self.guards = guards
    }

    /// Refreshes one folder. A failed listing throws and changes nothing, so an
    /// unreachable server can never look like deleted files.
    /// - Returns: `true` if anything changed.
    @discardableResult
    public func refresh(folderID: String, now: Date = Date()) async throws -> Bool {
        guard let folder = try store.item(id: folderID) else {
            throw store.missing(folderID)
        }
        let before = try store.currentAnchor()
        let path = try store.path(of: folderID)
        let listing = try await backend.list(path)

        guard let absent = try store.apply(
            listing: listing, in: folderID, generation: folder.generation, now: now)
        else {
            return false
        }

        let known = listing.count + absent.count
        let isMass = absent.count >= guards.massCount
            || (known > 0 && Double(absent.count) / Double(known) >= guards.massShare && absent.count > 1)
        let requiredPasses = isMass ? guards.passes + 1 : guards.passes

        for item in absent {
            try await check(item, requiredPasses: requiredPasses, now: now)
        }
        return try store.currentAnchor().sequence != before.sequence
    }

    /// Walks every folder on the server. After a recovery, macOS's re-import offers every item it
    /// holds, so each one has to be known here first, or it would look like a new file.
    public func refreshTree(limit: Int = 200_000, now: Date = Date()) async throws {
        var folders = [SyncItem.rootID]
        var next = 0
        while next < folders.count {
            // A walk that stops early mustn't pass for a finished one, or macOS would be asked to
            // match what it holds against a tree with parts missing.
            guard folders.count < limit else { throw SyncError.treeTooLarge }
            try await refresh(folderID: folders[next], now: now)
            folders += try store.children(of: folders[next]).filter { $0.kind == .directory }.map(\.id)
            next += 1
        }
    }

    /// Absence from a listing is never enough: only a direct not-found counts.
    private func check(_ item: SyncItem, requiredPasses: Int, now: Date) async throws {
        let path = try store.path(of: item.id)
        // Read before going to the server, so a change made during the check is noticed.
        guard let parentID = item.parentID,
              let parentGeneration = try store.item(id: parentID)?.generation
        else { return }
        do {
            _ = try await backend.item(at: path)
            try store.clearMissing(id: item.id, now: now)
        } catch RemoteError.notFound {
            let result = try store.recordMissingPass(id: item.id, now: now)
            if result.passes >= requiredPasses,
               now.timeIntervalSince(result.since) >= guards.minimumSpan {
                try store.removeConfirmed(item, parentGeneration: parentGeneration, now: now)
            }
        }
    }

    /// What one poll did.
    public struct PollResult: Sendable {
        public var checked = 0
        public var changed = false
        public var failures: [any Error] = []
    }

    /// Refreshes every folder that's due. A failed folder doesn't stop the others, and it's
    /// checked again next time.
    @discardableResult
    public func poll(
        recentWithin: TimeInterval = 3600,
        recentInterval: TimeInterval = 60,
        otherInterval: TimeInterval = 1800,
        now: Date = Date()
    ) async -> PollResult {
        var result = PollResult()
        let due: [SyncItem]
        do {
            due = try store.foldersDue(
                recentWithin: recentWithin,
                recentInterval: recentInterval,
                otherInterval: otherInterval,
                now: now)
        } catch {
            result.failures.append(error)
            return result
        }
        for folder in due {
            result.checked += 1
            do {
                if try await refresh(folderID: folder.id, now: now) {
                    result.changed = true
                }
            } catch {
                result.failures.append(error)
            }
        }
        return result
    }
}
