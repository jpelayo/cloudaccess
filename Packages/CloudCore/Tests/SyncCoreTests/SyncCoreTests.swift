// Apache 2 license - developer@infinitecontext.com

import CloudCore
import FakeRemote
import Foundation
import Testing
@testable import SyncCore

private func path(_ string: String) -> RemotePath {
    RemotePath(string)!
}

private func makeStore() throws -> SyncStore {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return try SyncStore(url: folder.appendingPathComponent("drive.sqlite"))
}

private let root = SyncItem.rootID

@Suite struct ListingTests {
    @Test func aFolderAppearsWithStableIDs() async throws {
        let store = try makeStore()
        let server = FakeRemote()
        await server.put(path("/a.txt"), content: Data("one".utf8))
        let syncer = Syncer(store: store, backend: server)

        try await syncer.refresh(folderID: root)
        let first = try #require(try store.child(of: root, named: "a.txt"))
        try await syncer.refresh(folderID: root)
        let second = try #require(try store.child(of: root, named: "a.txt"))
        #expect(first.id == second.id)
    }

    @Test func aRemoteEditReachesTheChangeLog() async throws {
        let store = try makeStore()
        let server = FakeRemote()
        await server.put(path("/a.txt"), content: Data("one".utf8))
        let syncer = Syncer(store: store, backend: server)
        try await syncer.refresh(folderID: root)
        let anchor = try store.currentAnchor()

        await server.put(path("/a.txt"), content: Data("two".utf8))
        let changed = try await syncer.refresh(folderID: root)

        #expect(changed)
        let changes = try store.changes(since: anchor)
        #expect(changes.updated.map(\.name) == ["a.txt"])
        #expect(changes.deleted.isEmpty)
    }

    @Test func aSameSizeEditIsCaughtByTheVersionTag() async throws {
        let store = try makeStore()
        let server = FakeRemote()
        await server.put(path("/a.txt"), content: Data("aaa".utf8))
        let syncer = Syncer(store: store, backend: server)
        try await syncer.refresh(folderID: root)
        let before = try #require(try store.child(of: root, named: "a.txt"))

        await server.put(path("/a.txt"), content: Data("bbb".utf8))
        try await syncer.refresh(folderID: root)
        let after = try #require(try store.child(of: root, named: "a.txt"))
        #expect(before.version != after.version)
    }

    @Test func nothingChangedLogsNothing() async throws {
        let store = try makeStore()
        let server = FakeRemote()
        await server.put(path("/a.txt"), content: Data("one".utf8))
        let syncer = Syncer(store: store, backend: server)
        try await syncer.refresh(folderID: root)
        let anchor = try store.currentAnchor()

        #expect(try await !syncer.refresh(folderID: root))
        #expect(try store.currentAnchor() == anchor)
    }
}

@Suite struct FalseDeleteTests {
    private func oneFile() async throws -> (SyncStore, FakeRemote, Syncer, Date) {
        let store = try makeStore()
        let server = FakeRemote()
        await server.put(path("/keep.txt"), content: Data("keep".utf8))
        await server.put(path("/other.txt"), content: Data("other".utf8))
        await server.put(path("/third.txt"), content: Data("third".utf8))
        await server.put(path("/fourth.txt"), content: Data("fourth".utf8))
        await server.put(path("/fifth.txt"), content: Data("fifth".utf8))
        await server.put(path("/sixth.txt"), content: Data("sixth".utf8))
        let syncer = Syncer(store: store, backend: server)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        try await syncer.refresh(folderID: root, now: now)
        return (store, server, syncer, now)
    }

    @Test func aFailedListingDeletesNothing() async throws {
        let (store, server, syncer, now) = try await oneFile()
        await server.fail(with: .unreachable("offline"))

        await #expect(throws: RemoteError.unreachable("offline")) {
            try await syncer.refresh(folderID: root, now: now.addingTimeInterval(120))
        }
        #expect(try store.children(of: root).count == 6)
    }

    @Test func aTruncatedListingDeletesNothing() async throws {
        let (store, server, syncer, now) = try await oneFile()
        await server.hideFromListings(path("/keep.txt"))

        // The item is missing from every listing, but a direct check still finds it.
        for pass in 1...5 {
            try await syncer.refresh(folderID: root, now: now.addingTimeInterval(Double(pass) * 120))
        }
        #expect(try store.child(of: root, named: "keep.txt") != nil)
    }

    @Test func onePassIsNotEnoughToDelete() async throws {
        let (store, server, syncer, now) = try await oneFile()
        await server.remove(path("/keep.txt"))

        try await syncer.refresh(folderID: root, now: now.addingTimeInterval(120))
        #expect(try store.child(of: root, named: "keep.txt") != nil)
    }

    @Test func twoPassesTooCloseTogetherAreNotEnough() async throws {
        let (store, server, syncer, now) = try await oneFile()
        await server.remove(path("/keep.txt"))

        try await syncer.refresh(folderID: root, now: now.addingTimeInterval(120))
        try await syncer.refresh(folderID: root, now: now.addingTimeInterval(125))
        #expect(try store.child(of: root, named: "keep.txt") != nil)
    }

    @Test func aConfirmedDeleteReachesTheChangeLog() async throws {
        let (store, server, syncer, now) = try await oneFile()
        let item = try #require(try store.child(of: root, named: "keep.txt"))
        let anchor = try store.currentAnchor()
        await server.remove(path("/keep.txt"))

        try await syncer.refresh(folderID: root, now: now.addingTimeInterval(120))
        try await syncer.refresh(folderID: root, now: now.addingTimeInterval(240))

        #expect(try store.child(of: root, named: "keep.txt") == nil)
        #expect(try store.changes(since: anchor).deleted == [item.id])
    }

    @Test func anItemThatReturnsIsKept() async throws {
        let (store, server, syncer, now) = try await oneFile()
        await server.remove(path("/keep.txt"))
        try await syncer.refresh(folderID: root, now: now.addingTimeInterval(120))

        await server.put(path("/keep.txt"), content: Data("back".utf8))
        try await syncer.refresh(folderID: root, now: now.addingTimeInterval(240))
        try await syncer.refresh(folderID: root, now: now.addingTimeInterval(360))
        #expect(try store.child(of: root, named: "keep.txt") != nil)
    }

    @Test func aMassDisappearanceNeedsAThirdPass() async throws {
        let (store, server, syncer, now) = try await oneFile()
        await server.remove(path("/keep.txt"))
        await server.remove(path("/other.txt"))
        await server.remove(path("/third.txt"))

        try await syncer.refresh(folderID: root, now: now.addingTimeInterval(120))
        try await syncer.refresh(folderID: root, now: now.addingTimeInterval(240))
        #expect(try store.children(of: root).count == 6)

        try await syncer.refresh(folderID: root, now: now.addingTimeInterval(360))
        #expect(try store.children(of: root).count == 3)
    }

    @Test func aListingRacingALocalChangeIsDiscarded() async throws {
        let store = try makeStore()
        let stale = [RemoteItem(path: path("/old.txt"), kind: .file, size: 1)]
        let generation = try #require(try store.item(id: root)).generation

        try store.recordCreated(RemoteItem(path: path("/new.txt"), kind: .file, size: 1), in: root)

        #expect(try store.apply(listing: stale, in: root, generation: generation) == nil)
        #expect(try store.child(of: root, named: "old.txt") == nil)
    }

    @Test func aLocalDeleteIsNotUndoneByAStaleListing() async throws {
        let store = try makeStore()
        let entry = RemoteItem(path: path("/gone.txt"), kind: .file, size: 4)
        let item = try store.recordCreated(entry, in: root)
        try store.recordDeleted(id: item.id)

        try store.apply(listing: [entry], in: root, generation: nil)
        #expect(try store.child(of: root, named: "gone.txt") == nil)
    }

    @Test func aTombstoneOnlyHidesThatExactVersion() async throws {
        let store = try makeStore()
        let old = RemoteItem(path: path("/file.txt"), kind: .file, size: 4)
        let item = try store.recordCreated(old, in: root)
        try store.recordDeleted(id: item.id)

        let recreated = RemoteItem(path: path("/file.txt"), kind: .file, size: 9)
        try store.apply(listing: [recreated], in: root, generation: nil)
        #expect(try store.child(of: root, named: "file.txt") != nil)
    }

    /// A restore is a move on the server, which keeps a file's version on some servers, and a
    /// folder has none. Without this, what came back stays hidden on the Mac that deleted it.
    @Test func aRestoredItemIsListedAgainOnTheMacThatDeletedIt() async throws {
        let store = try makeStore()
        let folder = try store.recordCreated(RemoteItem(path: path("/Work"), kind: .directory), in: root)
        let file = RemoteItem(path: path("/Work/Report.docx"), kind: .file, size: 4, versionID: "\"1\"")
        let restoredFolder = RemoteItem(path: path("/Old"), kind: .directory)
        try store.recordDeleted(id: try store.recordCreated(file, in: folder.id).id)
        try store.recordDeleted(id: try store.recordCreated(restoredFolder, in: root).id)

        try store.apply(listing: [file], in: folder.id, generation: nil)
        #expect(try store.child(of: folder.id, named: "Report.docx") == nil)

        #expect(try store.forgetDeletion(at: path("/Work/Report.docx")) == folder.id)
        #expect(try store.forgetDeletion(at: path("/Old")) == root)
        try store.apply(listing: [file], in: folder.id, generation: nil)
        try store.apply(listing: [RemoteItem(path: path("/Work"), kind: .directory), restoredFolder], in: root, generation: nil)
        #expect(try store.child(of: folder.id, named: "Report.docx") != nil)
        #expect(try store.child(of: root, named: "Old") != nil)
    }

    /// macOS was told an item was gone after a not-found that didn't last, and dropped its copy.
    /// While the server still has it, the next poll announces it again, whether the listing finds
    /// it or only a direct check does. Without that, it stays hidden on this Mac until it changes.
    @Test func aDoubtedItemThatsStillThereIsAnnouncedAgain() async throws {
        let (store, server, syncer, now) = try await oneFile()
        let keep = try #require(try store.child(of: root, named: "keep.txt"))
        let other = try #require(try store.child(of: root, named: "other.txt"))
        let anchor = try store.currentAnchor()
        await server.hideFromListings(path("/other.txt"))

        _ = try store.recordMissingPass(id: keep.id, now: now)
        _ = try store.recordMissingPass(id: other.id, now: now)
        try await syncer.refresh(folderID: root, now: now.addingTimeInterval(120))

        let announced = try Set(store.changes(since: anchor).updated.map(\.id))
        #expect(announced == [keep.id, other.id])
        #expect(try store.child(of: root, named: "keep.txt")?.id == keep.id)
        #expect(try store.child(of: root, named: "other.txt")?.id == other.id)

        // Once announced, an unchanged item isn't announced again.
        let after = try store.currentAnchor()
        try await syncer.refresh(folderID: root, now: now.addingTimeInterval(240))
        #expect(try store.changes(since: after).updated.isEmpty)
    }

    @Test func aRestoreIntoAnUnknownFolderForgetsNothing() async throws {
        let store = try makeStore()
        #expect(try store.forgetDeletion(at: path("/Nowhere/Report.docx")) == nil)
    }
}

@Suite struct IdentityTests {
    @Test func renamingAFolderKeepsIDsAndChangesPaths() throws {
        let store = try makeStore()
        let folder = try store.recordCreated(RemoteItem(path: path("/a"), kind: .directory), in: root)
        let file = try store.recordCreated(RemoteItem(path: path("/a/f.txt"), kind: .file, size: 1), in: folder.id)

        try store.recordMoved(id: folder.id, to: root, name: "b")

        #expect(try store.path(of: file.id).description == "/b/f.txt")
        #expect(try store.child(of: folder.id, named: "f.txt")?.id == file.id)
    }

    @Test func movingAFileKeepsItsID() throws {
        let store = try makeStore()
        let one = try store.recordCreated(RemoteItem(path: path("/one"), kind: .directory), in: root)
        let two = try store.recordCreated(RemoteItem(path: path("/two"), kind: .directory), in: root)
        let file = try store.recordCreated(RemoteItem(path: path("/one/f"), kind: .file, size: 1), in: one.id)

        try store.recordMoved(id: file.id, to: two.id, name: "g")
        #expect(try store.path(of: file.id).description == "/two/g")
    }

    @Test func deletingAFolderRemovesWhatsInside() throws {
        let store = try makeStore()
        let folder = try store.recordCreated(RemoteItem(path: path("/a"), kind: .directory), in: root)
        let file = try store.recordCreated(RemoteItem(path: path("/a/f"), kind: .file, size: 1), in: folder.id)

        try store.recordDeleted(id: folder.id)
        #expect(try store.item(id: file.id) == nil)
    }
}

@Suite struct AnchorTests {
    @Test func anAnchorRoundTrips() throws {
        let anchor = SyncAnchor(epoch: "abc", sequence: 42)
        #expect(SyncAnchor(encoded: anchor.encoded) == anchor)
    }

    @Test func anotherEpochExpires() throws {
        let store = try makeStore()
        #expect(throws: SyncError.anchorExpired) {
            try store.changes(since: SyncAnchor(epoch: "other", sequence: 0))
        }
    }

    @Test func aPrunedAnchorExpires() async throws {
        let store = try makeStore()
        let server = FakeRemote()
        await server.put(path("/a"), content: Data("x".utf8))
        let early = Date(timeIntervalSince1970: 1_000_000_000)
        let anchor = try store.currentAnchor()
        try await Syncer(store: store, backend: server).refresh(folderID: root, now: early)

        try store.prune(now: early.addingTimeInterval(SyncStore.changeLogLifetime + 1))
        #expect(throws: SyncError.anchorExpired) {
            try store.changes(since: anchor)
        }
    }

    @Test func changesAreCollapsedToTheLatest() async throws {
        let store = try makeStore()
        let server = FakeRemote()
        await server.put(path("/a"), content: Data("1".utf8))
        let syncer = Syncer(store: store, backend: server)
        let anchor = try store.currentAnchor()
        try await syncer.refresh(folderID: root)
        await server.put(path("/a"), content: Data("2".utf8))
        try await syncer.refresh(folderID: root)

        #expect(try store.changes(since: anchor).updated.count == 1)
    }

    @Test func aCaughtUpAnchorHasNoChanges() async throws {
        let store = try makeStore()
        let server = FakeRemote()
        await server.put(path("/a"), content: Data("1".utf8))
        try await Syncer(store: store, backend: server).refresh(folderID: root)
        let changes = try store.changes(since: try store.currentAnchor())
        #expect(changes.updated.isEmpty && changes.deleted.isEmpty)
    }
}

@Suite struct PollingTests {
    @Test func foldersNeverOpenedAreNotChecked() async throws {
        let store = try makeStore()
        let server = FakeRemote()
        await server.makeFolder(path("/never"))
        let syncer = Syncer(store: store, backend: server)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        try await syncer.refresh(folderID: root, now: now)
        let before = await server.listingCount

        await syncer.poll(now: now.addingTimeInterval(7200))
        // Only the root is polled, because /never was never listed.
        #expect(await server.listingCount == before + 1)
    }

    @Test func recentFoldersAreCheckedSooner() async throws {
        let store = try makeStore()
        let server = FakeRemote()
        let syncer = Syncer(store: store, backend: server)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        try await syncer.refresh(folderID: root, now: now)
        try store.markOpened(id: root, now: now)
        let before = await server.listingCount

        await syncer.poll(now: now.addingTimeInterval(30))
        #expect(await server.listingCount == before)
        await syncer.poll(now: now.addingTimeInterval(90))
        #expect(await server.listingCount == before + 1)
    }

    @Test func aFailedFolderDoesntStopThePoll() async throws {
        let store = try makeStore()
        let server = FakeRemote()
        let syncer = Syncer(store: store, backend: server)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        try await syncer.refresh(folderID: root, now: now)
        await server.fail(with: .unreachable("offline"))

        let result = await syncer.poll(now: now.addingTimeInterval(7200))
        #expect(result.changed == false)
        #expect(result.failures.count == 1)
    }

    private func localCopy(
        _ name: String, size: Int64, usedAt date: Date, in store: SyncStore
    ) throws -> String {
        let entry = RemoteItem(path: path("/\(name)"), kind: .file, size: size, modified: nil, versionID: nil)
        let saved = try store.recordCreated(entry, in: root)
        try store.markLocal(id: saved.id, size: size, now: date)
        return saved.id
    }

    @Test func anIdleCopyIsRemovedAndARecentOneStays() throws {
        let store = try makeStore()
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let old = try localCopy("old", size: 10, usedAt: now.addingTimeInterval(-7200), in: store)
        _ = try localCopy("recent", size: 10, usedAt: now.addingTimeInterval(-60), in: store)

        #expect(try store.copiesToRemove(idleFor: 3600, sizeLimit: nil, now: now) == [old])
    }

    /// macOS treats "no such item" as deleted on the server, and drops its copy. A database that's
    /// still reading the server back can't know that, and found on a real mount, this lost sight of
    /// five files. They were safe on the server, but Finder never showed them again.
    @Test func anItemARecoveryHasntReachedIsNeverCalledGone() throws {
        let store = try makeStore()
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        #expect(store.missing("unknown", now: now) == .itemNotFound("unknown"))

        try store.setNeedsRebuild(true)
        #expect(store.missing("unknown", now: now) == .recovering)
        #expect(throws: SyncError.recovering) { try store.path(of: "unknown") }
    }

    /// macOS offers what it holds one item at a time, so an old identifier can still arrive after
    /// the database is rebuilt. The call asking for this returns as soon as it has begun.
    @Test func aRecoveryLastsUntilMacOSHasFinishedImporting() throws {
        let store = try makeStore()
        let started = Date(timeIntervalSince1970: 2_000_000_000)
        try store.setNeedsRebuild(true)
        try store.noteImportStarted(now: started)
        try store.setNeedsRebuild(false)

        let hoursLater = started.addingTimeInterval(6 * 3600)
        #expect(try store.isRecovering(now: hoursLater))
        #expect(store.missing("unknown", now: hoursLater) == .recovering)

        try store.noteImportFinished()
        #expect(try !store.isRecovering(now: hoursLater))
        #expect(store.missing("unknown", now: hoursLater) == .itemNotFound("unknown"))
    }

    /// A small import can finish before the call that asked for it has returned.
    @Test func anImportThatFinishesFirstStillCounts() throws {
        let store = try makeStore()
        try store.setNeedsRebuild(true)
        try store.noteImportStarted()
        try store.noteImportFinished()
        try store.setNeedsRebuild(false)
        #expect(try !store.isRecovering())
    }

    /// In case macOS never says, an item can't wait forever to be called gone.
    @Test func anImportThatNeverReportsIsGivenUpOn() throws {
        let store = try makeStore()
        let started = Date(timeIntervalSince1970: 2_000_000_000)
        try store.noteImportStarted(now: started)
        #expect(try !store.isRecovering(now: started.addingTimeInterval(SyncStore.importLimit + 1)))
    }

    /// A read failure isn't evidence of anything, and macOS would drop its copy on "gone".
    @Test func aDatabaseThatCantTellNeverSaysGone() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("state.sqlite")
        let store = try SyncStore(url: url)
        let drop = Process()
        drop.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        drop.arguments = [url.path, "DROP TABLE meta"]
        try drop.run()
        drop.waitUntilExit()

        #expect(store.missing("unknown") == .recovering)
    }

    @Test func aWalkThatCantFinishSaysSo() async throws {
        let server = FakeRemote()
        let store = try makeStore()
        let syncer = Syncer(store: store, backend: server)
        await server.put(path("/child/kept.txt"), content: Data("kept".utf8))

        await #expect(throws: SyncError.treeTooLarge) {
            try await syncer.refreshTree(limit: 2)
        }
    }

    @Test func aWalkThatFitsFindsEverything() async throws {
        let server = FakeRemote()
        let store = try makeStore()
        let syncer = Syncer(store: store, backend: server)
        await server.put(path("/child/deeper/kept.txt"), content: Data("kept".utf8))

        try await syncer.refreshTree()

        let child = try #require(try store.child(of: root, named: "child"))
        let deeper = try #require(try store.child(of: child.id, named: "deeper"))
        #expect(try store.child(of: deeper.id, named: "kept.txt") != nil)
    }

    @Test func aDriveThatNeverRecoveredIsSettled() throws {
        #expect(try !makeStore().isRecovering())
    }

    /// macOS backs off further each time, so a file that was only busy could wait for hours.
    @Test func aBusyFileAsksForARetryAfterAMinute() throws {
        let store = try makeStore()
        let noted = Date(timeIntervalSince1970: 2_000_000_000)
        #expect(try !store.takeBusyRetry(now: noted))

        try store.noteBusyFile(now: noted)
        #expect(try !store.takeBusyRetry(now: noted.addingTimeInterval(30)))
        #expect(try store.takeBusyRetry(now: noted.addingTimeInterval(61)))
        #expect(try !store.takeBusyRetry(now: noted.addingTimeInterval(62)))
    }

    /// Files busy again and again mustn't keep putting the retry off.
    @Test func moreBusyFilesDontDelayTheRetry() throws {
        let store = try makeStore()
        let noted = Date(timeIntervalSince1970: 2_000_000_000)
        try store.noteBusyFile(now: noted)
        try store.noteBusyFile(now: noted.addingTimeInterval(50))

        #expect(try store.takeBusyRetry(now: noted.addingTimeInterval(61)))
    }

    /// Nothing but the app clears this mark, so it can't be allowed to outlive the app. If it did,
    /// quitting while offline would hold every upload until someone opened the app again.
    @Test func anOfflineMarkFadesOnceTheAppStopsRenewingIt() throws {
        let store = try makeStore()
        let marked = Date(timeIntervalSince1970: 2_000_000_000)
        try store.setOffline(true, now: marked)

        #expect(try store.isOffline(now: marked.addingTimeInterval(30)))
        #expect(try !store.isOffline(now: marked.addingTimeInterval(SyncStore.offlineMarkLifetime + 1)))
    }

    @Test func aFailureReachesMacOSSoItsBadgeShows() throws {
        let store = try makeStore()
        let entry = RemoteItem(path: path("/doc.txt"), kind: .file, size: 1, modified: nil, versionID: "v")
        let item = try store.recordCreated(entry, in: root)
        let before = try store.currentAnchor()

        try store.recordFailure(id: item.id, name: item.name, message: "No")
        #expect(try store.hasFailure(id: item.id))
        #expect(try store.changes(since: before, limit: 10).updated.map(\.id) == [item.id])

        let failed = try store.currentAnchor()
        try store.clearFailure(id: item.id)
        #expect(try !store.hasFailure(id: item.id))
        #expect(try store.changes(since: failed, limit: 10).updated.map(\.id) == [item.id])
    }

    /// A retry fails the same way many times, and each would otherwise wake macOS.
    @Test func repeatingAFailureSaysNothingNew() throws {
        let store = try makeStore()
        let entry = RemoteItem(path: path("/doc.txt"), kind: .file, size: 1, modified: nil, versionID: "v")
        let item = try store.recordCreated(entry, in: root)
        try store.recordFailure(id: item.id, name: item.name, message: "No")
        let after = try store.currentAnchor()

        try store.recordFailure(id: item.id, name: item.name, message: "No again")

        #expect(try store.changes(since: after, limit: 10).updated.isEmpty)
    }

    @Test func aFailureOnANewFileHasNoItemToTell() throws {
        let store = try makeStore()
        let before = try store.currentAnchor()
        try store.recordFailure(id: "new:root/doc.txt", name: "doc.txt", message: "No")
        try store.clearFailure(id: "new:root/doc.txt")
        #expect(try store.changes(since: before, limit: 10).updated.isEmpty)
    }

    @Test func aFailedNewFileSaysWhereItIs() throws {
        let store = try makeStore()
        let entry = RemoteItem(path: path("/Books"), kind: .directory, size: nil, modified: nil, versionID: nil)
        let folder = try store.recordCreated(entry, in: root)

        try store.recordFailure(id: "new:\(folder.id)/long name.pdf", name: "long name.pdf", message: "No")

        let failure = try #require(try store.failures().first)
        #expect(failure.isUnsentFile)
        #expect(store.path(of: failure) == path("/Books/long name.pdf"))
    }

    @Test func aFailedNewFileAtTheTopSaysWhereItIs() throws {
        let store = try makeStore()
        try store.recordFailure(id: "new:\(root)/doc.txt", name: "doc.txt", message: "No")
        let failure = try #require(try store.failures().first)
        #expect(store.path(of: failure) == path("/doc.txt"))
    }

    @Test func aFailedKnownFileSaysWhereItIs() throws {
        let store = try makeStore()
        let entry = RemoteItem(path: path("/doc.txt"), kind: .file, size: 1, modified: nil, versionID: "v")
        let item = try store.recordCreated(entry, in: root)
        try store.recordFailure(id: item.id, name: item.name, message: "No")
        let failure = try #require(try store.failures().first)
        #expect(!failure.isUnsentFile)
        #expect(store.path(of: failure) == path("/doc.txt"))
    }

    @Test func aFailureInAFolderThatWentSaysNothing() throws {
        let store = try makeStore()
        try store.recordFailure(id: "new:gone/doc.txt", name: "doc.txt", message: "No")
        let failure = try #require(try store.failures().first)
        #expect(store.path(of: failure) == nil)
    }

    /// A download long ago says nothing about a file someone opened this morning.
    @Test func aCopyMacOSSaysWasUsedIsntIdle() throws {
        let store = try makeStore()
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let id = try localCopy("in-use", size: 10, usedAt: now.addingTimeInterval(-7200), in: store)

        try store.noteUsed(id: id, at: now.addingTimeInterval(-60))

        #expect(try store.copiesToRemove(idleFor: 3600, sizeLimit: nil, now: now).isEmpty)
    }

    @Test func anOldUseNeverMakesAFreshCopyLookIdle() throws {
        let store = try makeStore()
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let id = try localCopy("fresh", size: 10, usedAt: now.addingTimeInterval(-60), in: store)

        try store.noteUsed(id: id, at: now.addingTimeInterval(-7200))

        #expect(try store.copiesToRemove(idleFor: 3600, sizeLimit: nil, now: now).isEmpty)
    }

    @Test func reconcilingTakesWhatMacOSSaysAboutUse() throws {
        let store = try makeStore()
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let id = try localCopy("known", size: 10, usedAt: now.addingTimeInterval(-7200), in: store)
        let entry = RemoteItem(path: path("/found"), kind: .file, size: 10, modified: nil, versionID: nil)
        let found = try store.recordCreated(entry, in: root).id
        let used = now.addingTimeInterval(-60)

        try store.reconcile(onDisk: [id, found], lastUsed: [id: used, found: used], now: now)

        #expect(try store.copiesToRemove(idleFor: 3600, sizeLimit: nil, now: now).isEmpty)
    }

    @Test func overTheSizeLimitTheOldestGoFirst() throws {
        let store = try makeStore()
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let oldest = try localCopy("a", size: 60, usedAt: now.addingTimeInterval(-300), in: store)
        let older = try localCopy("b", size: 60, usedAt: now.addingTimeInterval(-200), in: store)
        _ = try localCopy("c", size: 60, usedAt: now.addingTimeInterval(-100), in: store)

        #expect(try store.copiesToRemove(idleFor: nil, sizeLimit: 100, now: now) == [oldest, older])
    }

    @Test func withBothRulesOffNothingIsRemoved() throws {
        let store = try makeStore()
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        _ = try localCopy("kept", size: 1 << 40, usedAt: now.addingTimeInterval(-1_000_000), in: store)

        #expect(try store.copiesToRemove(idleFor: nil, sizeLimit: nil, now: now).isEmpty)
    }

    @Test func aFreshlyUsedCopyIsSafeAgain() throws {
        let store = try makeStore()
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let id = try localCopy("file", size: 10, usedAt: now.addingTimeInterval(-7200), in: store)

        try store.markLocal(id: id, size: 10, now: now)

        #expect(try store.copiesToRemove(idleFor: 3600, sizeLimit: nil, now: now).isEmpty)
    }

    @Test func aDeletedItemLeavesNoCopyBehind() throws {
        let store = try makeStore()
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let id = try localCopy("gone", size: 10, usedAt: now.addingTimeInterval(-7200), in: store)
        try store.recordDeleted(id: id)

        #expect(try store.copiesToRemove(idleFor: 3600, sizeLimit: nil, now: now).isEmpty)
        #expect(try store.localCopiesSize() == 0)
    }

    @Test func aNewerDatabaseIsLeftAlone() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("newer-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try SyncStore(url: url)
        let raw = try Database(url: url)
        try raw.execute("PRAGMA user_version = 999")

        #expect(throws: SyncError.newerDatabase) {
            _ = try SyncStore(url: url)
        }
    }

    @Test func anOlderDatabaseIsUpgradedAfterABackup() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("older-\(UUID().uuidString).sqlite")
        let backup = url.deletingPathExtension().appendingPathExtension("before-upgrade")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: backup)
        }
        let store = try SyncStore(url: url)
        try store.recordCreated(RemoteItem(path: path("/a.txt"), kind: .file, size: 1), in: root)
        let raw = try Database(url: url)
        try raw.execute("PRAGMA user_version = 1")

        let upgraded = try SyncStore(url: url)

        #expect(try upgraded.child(of: root, named: "a.txt") != nil)
        #expect(FileManager.default.fileExists(atPath: backup.path))
    }

    @Test func aBackupHoldsTheItems() async throws {
        let store = try makeStore()
        let server = FakeRemote()
        await server.put(path("/a.txt"), content: Data("x".utf8))
        try await Syncer(store: store, backend: server).refresh(folderID: root)
        let backup = FileManager.default.temporaryDirectory
            .appendingPathComponent("backup-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: backup) }

        try store.backUp(to: backup)

        #expect(try SyncStore(url: backup).child(of: root, named: "a.txt") != nil)
    }

    @Test func aFullPruneDoesntTakeTheAnchorBackwards() async throws {
        let store = try makeStore()
        let server = FakeRemote()
        await server.put(path("/a.txt"), content: Data("x".utf8))
        let syncer = Syncer(store: store, backend: server)
        let long = Date(timeIntervalSince1970: 2_000_000_000)
        try await syncer.refresh(folderID: root, now: long)
        let before = try store.currentAnchor()

        try store.prune(now: long.addingTimeInterval(SyncStore.changeLogLifetime + 86_400))

        let after = try store.currentAnchor()
        #expect(after.sequence >= before.sequence)
        #expect(try store.changes(since: after).updated.isEmpty)
    }

    @Test func changesGoOutInBatches() async throws {
        let store = try makeStore()
        let server = FakeRemote()
        for number in 0..<5 {
            await server.put(path("/\(number).txt"), content: Data("x".utf8))
        }
        try await Syncer(store: store, backend: server).refresh(folderID: root)

        var anchor = SyncAnchor(epoch: try store.currentAnchor().epoch, sequence: 0)
        var seen = 0
        var batches = 0
        while true {
            let changes = try store.changes(since: anchor, limit: 2)
            seen += changes.updated.count
            batches += 1
            anchor = changes.anchor
            if !changes.moreComing { break }
        }
        #expect(seen == 5)
        #expect(batches == 3)
    }

    @Test func foldersPageInAStableOrder() async throws {
        let store = try makeStore()
        let server = FakeRemote()
        for number in 0..<5 {
            await server.put(path("/\(number).txt"), content: Data("x".utf8))
        }
        try await Syncer(store: store, backend: server).refresh(folderID: root)

        let first = try store.children(of: root, after: nil, limit: 3)
        let second = try store.children(of: root, after: first.last?.id, limit: 3)
        #expect(first.count == 3)
        #expect(second.count == 2)
        #expect(Set((first + second).map(\.id)).count == 5)
    }

    @Test func aFolderReplacedByAFileGetsANewIdentity() async throws {
        let store = try makeStore()
        let server = FakeRemote()
        await server.put(path("/thing/inside.txt"), content: Data("x".utf8))
        let syncer = Syncer(store: store, backend: server)
        try await syncer.refresh(folderID: root)
        let folder = try #require(try store.child(of: root, named: "thing"))
        try await syncer.refresh(folderID: folder.id)

        await server.remove(path("/thing"))
        await server.put(path("/thing"), content: Data("now a file".utf8))
        try await syncer.refresh(folderID: root)

        let file = try #require(try store.child(of: root, named: "thing"))
        #expect(file.kind == .file)
        #expect(file.id != folder.id)
        #expect(try store.children(of: folder.id).isEmpty)
    }

    @Test func namesDifferingOnlyInUnicodeFormStaySeparate() async throws {
        let store = try makeStore()
        let listing = [
            RemoteItem(path: path("/caf\u{e9}.txt"), kind: .file, size: 1),
            RemoteItem(path: path("/cafe\u{301}.txt"), kind: .file, size: 2),
        ]

        try store.apply(listing: listing, in: root, generation: nil)
        try store.apply(listing: listing, in: root, generation: nil)

        #expect(try store.children(of: root).count == 2)
    }

    @Test func reconcilingFollowsWhatMacOSHasOnDisk() async throws {
        let store = try makeStore()
        let server = FakeRemote()
        await server.put(path("/kept.txt"), content: Data("x".utf8))
        await server.put(path("/gone.txt"), content: Data("xx".utf8))
        await server.put(path("/new.txt"), content: Data("xxx".utf8))
        await server.put(path("/folder/inner.txt"), content: Data("x".utf8))
        try await Syncer(store: store, backend: server).refresh(folderID: root)
        let kept = try #require(try store.child(of: root, named: "kept.txt"))
        let gone = try #require(try store.child(of: root, named: "gone.txt"))
        let new = try #require(try store.child(of: root, named: "new.txt"))
        try store.markLocal(id: kept.id, size: 1)
        try store.markLocal(id: gone.id, size: 2)

        try store.reconcile(onDisk: [kept.id, new.id])

        #expect(try store.localCopiesSize() == 4)
    }

    @Test func aFolderOnDiskStaysRecent() async throws {
        let store = try makeStore()
        let server = FakeRemote()
        await server.makeFolder(path("/folder"))
        let syncer = Syncer(store: store, backend: server)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        try await syncer.refresh(folderID: root, now: now)
        let folder = try #require(try store.child(of: root, named: "folder"))
        try await syncer.refresh(folderID: folder.id, now: now)

        let later = now.addingTimeInterval(7200)
        try store.reconcile(onDisk: [folder.id], now: later)

        let due = try store.foldersDue(
            recentWithin: 3600, recentInterval: 60, otherInterval: 1_000_000, now: later.addingTimeInterval(90))
        #expect(due.map(\.id).contains(folder.id))
    }

    @Test func aPendingSignalSurvivesUntilItsDone() async throws {
        let store = try makeStore()
        let server = FakeRemote()
        await server.put(path("/a.txt"), content: Data("x".utf8))
        try await Syncer(store: store, backend: server).refresh(folderID: root)

        let pending = try #require(try store.pendingSignal())
        #expect(try store.pendingSignal() == pending)

        try store.markSignalled(upTo: pending)
        #expect(try store.pendingSignal() == nil)
    }

    @Test func aForgedSizeCantCrashTheCacheRules() throws {
        let store = try makeStore()
        let first = try store.recordCreated(
            RemoteItem(path: path("/a"), kind: .file, size: .max), in: root)
        let second = try store.recordCreated(
            RemoteItem(path: path("/b"), kind: .file, size: .max), in: root)
        try store.markLocal(id: first.id, size: .max)
        try store.markLocal(id: second.id, size: .max)

        #expect(try !store.copiesToRemove(idleFor: nil, sizeLimit: 10).isEmpty)
    }

    /// macOS may work only from the working set and never list the root, so a poll can't wait for it.
    @Test func aRootNeverListedIsStillPolled() async throws {
        let store = try makeStore()
        let server = FakeRemote()
        await server.put(path("/remote.txt"), content: Data("from elsewhere".utf8))
        let syncer = Syncer(store: store, backend: server)

        let result = await syncer.poll()

        #expect(result.checked == 1)
        #expect(result.changed)
        #expect(try store.children(of: root).map(\.name) == ["remote.txt"])
    }

    @Test func aPeerFileReachesAPolledRoot() async throws {
        let store = try makeStore()
        let server = FakeRemote()
        let syncer = Syncer(store: store, backend: server)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        await syncer.poll(now: now)

        await server.put(path("/later.txt"), content: Data("x".utf8))

        #expect(await syncer.poll(now: now.addingTimeInterval(30)).checked == 0)
        #expect(await syncer.poll(now: now.addingTimeInterval(90)).changed)
    }
}

@Suite struct DatabaseRecoveryTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func entry(_ name: String) -> RemoteItem {
        RemoteItem(path: RemotePath("/\(name)")!, kind: .file, size: 1, versionID: "v1")
    }

    private func damage(_ url: URL) throws {
        try Data(repeating: 0x41, count: 8192).write(to: url)
        for suffix in ["-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
    }

    @Test func aNewDriveIsNotARecovery() throws {
        let base = try folder()
        let opened = try SyncStore.opening(
            url: base.appendingPathComponent("a.sqlite"), backup: base.appendingPathComponent("a.backup"))
        #expect(opened.recovery == .none)
    }

    @Test func aHealthyDatabaseIsLeftAlone() throws {
        let base = try folder()
        let url = base.appendingPathComponent("a.sqlite")
        let backup = base.appendingPathComponent("a.backup")
        let id = try SyncStore(url: url).recordCreated(entry("kept.txt"), in: SyncItem.rootID).id
        let opened = try SyncStore.opening(url: url, backup: backup)
        #expect(opened.recovery == .none)
        #expect(try opened.store.item(id: id)?.name == "kept.txt")
    }

    @Test func aDamagedDatabaseComesBackFromItsBackup() throws {
        let base = try folder()
        let url = base.appendingPathComponent("a.sqlite")
        let backup = base.appendingPathComponent("a.backup")
        var id = ""
        var anchor: SyncAnchor?
        do {
            let store = try SyncStore(url: url)
            id = try store.recordCreated(entry("kept.txt"), in: SyncItem.rootID).id
            anchor = try store.currentAnchor()
            try store.backUp(to: backup)
        }
        try damage(url)

        let opened = try SyncStore.opening(url: url, backup: backup)

        #expect(opened.recovery == .restoredFromBackup)
        #expect(try opened.store.item(id: id)?.name == "kept.txt")
        // macOS may be ahead of the backup, so what it holds has to expire.
        #expect(throws: SyncError.anchorExpired) {
            _ = try opened.store.changes(since: anchor!)
        }
        #expect(FileManager.default.fileExists(atPath: url.path + ".damaged"))
    }

    @Test func aMissingDatabaseComesBackFromItsBackup() throws {
        let base = try folder()
        let url = base.appendingPathComponent("a.sqlite")
        let backup = base.appendingPathComponent("a.backup")
        var id = ""
        do {
            let store = try SyncStore(url: url)
            id = try store.recordCreated(entry("kept.txt"), in: SyncItem.rootID).id
            try store.backUp(to: backup)
        }
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }

        let opened = try SyncStore.opening(url: url, backup: backup)

        #expect(opened.recovery == .restoredFromBackup)
        #expect(try opened.store.item(id: id) != nil)
    }

    @Test func aDamagedDatabaseWithNoBackupStartsAgain() throws {
        let base = try folder()
        let url = base.appendingPathComponent("a.sqlite")
        do { _ = try SyncStore(url: url) }
        try damage(url)

        let opened = try SyncStore.opening(url: url, backup: base.appendingPathComponent("a.backup"))

        #expect(opened.recovery == .startedAgain)
        #expect(try opened.store.item(id: SyncItem.rootID) != nil)
    }

    @Test func aDamagedBackupStartsAgainToo() throws {
        let base = try folder()
        let url = base.appendingPathComponent("a.sqlite")
        let backup = base.appendingPathComponent("a.backup")
        do { _ = try SyncStore(url: url) }
        try damage(url)
        try Data(repeating: 0x42, count: 8192).write(to: backup)

        let opened = try SyncStore.opening(url: url, backup: backup)

        #expect(opened.recovery == .startedAgain)
    }

    /// SQLite takes an empty file for a new database. For a drive that has had one, that's a
    /// loss: a new, settled database would tell macOS that everything it holds is gone.
    @Test func anEmptiedDatabaseIsALossNotANewDrive() throws {
        let base = try folder()
        let url = base.appendingPathComponent("a.sqlite")
        let backup = base.appendingPathComponent("a.backup")
        do {
            let store = try SyncStore.opening(url: url, backup: backup).store
            _ = try store.recordCreated(entry("kept.txt"), in: SyncItem.rootID)
        }
        try Data().write(to: url)
        for suffix in ["-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }

        let opened = try SyncStore.opening(url: url, backup: backup)

        #expect(opened.recovery == .startedAgain)
        #expect(try opened.store.isRecovering())
    }

    /// A repair builds its replacement aside, and flags it before it takes the database's name.
    /// A crash, or the other process opening the database meanwhile, then never finds a restored
    /// or empty database that looks settled.
    @Test func aReplacementIsFlaggedBeforeItGetsTheDatabasesName() throws {
        for hasBackup in [true, false] {
            let base = try folder()
            let url = base.appendingPathComponent("a.sqlite")
            let backup = base.appendingPathComponent("a.backup")
            do {
                let store = try SyncStore(url: url)
                _ = try store.recordCreated(entry("kept.txt"), in: SyncItem.rootID)
                if hasBackup {
                    try store.backUp(to: backup)
                }
            }
            try damage(url)

            var checked = false
            let opened = try SyncStore.opening(url: url, backup: backup) { replacement in
                #expect(replacement != url, "backup: \(hasBackup)")
                #expect(!FileManager.default.fileExists(atPath: url.path), "backup: \(hasBackup)")
                let isFlagged = (try? SyncStore(url: replacement).needsRebuild()) == true
                #expect(isFlagged, "backup: \(hasBackup)")
                checked = true
            }

            #expect(checked)
            #expect(opened.recovery == (hasBackup ? .restoredFromBackup : .startedAgain))
            #expect(try opened.store.needsRebuild())
            #expect(!FileManager.default.fileExists(atPath: url.path + ".rebuilding"))
        }
    }
}

@Suite struct OfflineTests {
    private func store() throws -> SyncStore {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try SyncStore(url: folder.appendingPathComponent("a.sqlite"))
    }

    private func entry(_ name: String) -> RemoteItem {
        RemoteItem(path: RemotePath("/\(name)")!, kind: .file, size: 1, versionID: "v1")
    }

    @Test func theOfflineFlagIsSharedThroughTheDatabase() throws {
        let store = try store()
        #expect(try store.isOffline() == false)
        try store.setOffline(true)
        #expect(try store.isOffline())
        try store.setOffline(false)
        #expect(try store.isOffline() == false)
    }

    @Test func aNewSignInIsCountedThroughTheDatabase() throws {
        let store = try store()
        #expect(try store.signInRevision() == 0)
        try store.raiseSignInRevision()
        try store.raiseSignInRevision()
        #expect(try store.signInRevision() == 2)
    }

    @Test func onlyFilesWithNoLocalCopyAreAnnounced() throws {
        let store = try store()
        let kept = try store.recordCreated(entry("kept.txt"), in: SyncItem.rootID)
        let remote = try store.recordCreated(entry("remote.txt"), in: SyncItem.rootID)
        try store.markLocal(id: kept.id, size: 1)
        let before = try store.currentAnchor()

        #expect(try store.setShowsUnavailable(true))

        let changes = try store.changes(since: before)
        #expect(changes.updated.map(\.id) == [remote.id])
        #expect(try store.hasLocalCopy(id: kept.id))
        #expect(try store.hasLocalCopy(id: remote.id) == false)
    }

    @Test func goingBackOnlineAnnouncesThemAgain() throws {
        let store = try store()
        let remote = try store.recordCreated(entry("remote.txt"), in: SyncItem.rootID)
        try store.setShowsUnavailable(true)
        let before = try store.currentAnchor()

        #expect(try store.setShowsUnavailable(false))

        #expect(try store.changes(since: before).updated.map(\.id) == [remote.id])
        #expect(try store.showsUnavailable() == false)
    }

    @Test func repeatingAStateAnnouncesNothing() throws {
        let store = try store()
        _ = try store.recordCreated(entry("remote.txt"), in: SyncItem.rootID)
        try store.setShowsUnavailable(true)
        let before = try store.currentAnchor()

        #expect(try store.setShowsUnavailable(true) == false)

        #expect(try store.changes(since: before).updated.isEmpty)
    }

    @Test func aHugeDriveIsCapped() throws {
        let store = try store()
        for index in 0..<5 {
            _ = try store.recordCreated(entry("file-\(index).txt"), in: SyncItem.rootID)
        }
        let before = try store.currentAnchor()

        try store.setShowsUnavailable(true, limit: 2)

        #expect(try store.changes(since: before).updated.count == 2)
    }
}
