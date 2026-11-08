// Apache 2 license - developer@infinitecontext.com

import CloudCore
import FakeRemote
import Foundation
import MountKit
import Synchronization
import SyncCore
import Testing

@Suite struct MutationsTests {
    private let root = SyncItem.rootID

    private func path(_ text: String) -> RemotePath {
        RemotePath(text)!
    }

    /// A drive with a simulated server, and a place for local files.
    private struct Drive {
        let server = FakeRemote()
        let store: SyncStore
        let syncer: Syncer
        let mutations: Mutations
        let folder: URL

        init() throws {
            folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("MountKitTests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            store = try SyncStore(url: folder.appendingPathComponent("state.sqlite"))
            syncer = Syncer(store: store, backend: server)
            mutations = Mutations(backend: server, store: store, syncer: syncer)
        }

        func local(_ text: String) throws -> URL {
            let url = folder.appendingPathComponent(UUID().uuidString)
            try Data(text.utf8).write(to: url)
            return url
        }

        func text(at location: RemotePath) async -> String? {
            await server.content(at: location).map { String(decoding: $0, as: UTF8.self) }
        }

        /// What macOS holds as the base after syncing this item.
        func base(of id: String) throws -> String? {
            try store.item(id: id).map(ItemVersions.content(of:)).flatMap {
                String(data: $0, encoding: .utf8)
            }
        }
    }

    private func synced(_ drive: Drive, _ location: String, _ text: String) async throws -> SyncItem {
        await drive.server.put(path(location), content: Data(text.utf8))
        try await drive.syncer.refresh(folderID: root)
        return try #require(try drive.store.child(of: root, named: path(location).name))
    }

    /// macOS never lists a folder made on this Mac, because it already knows what's in it. So
    /// without this, a peer's file in that folder wouldn't arrive until much later.
    @Test func aPeersFileInAFolderMadeHereArrives() async throws {
        let drive = try Drive()
        let folder = try await drive.mutations.create(
            name: "made-here", parentID: root, isFolder: true, contents: nil, mayAlreadyExist: false)

        await drive.server.put(path("/made-here/from-a-peer.txt"), content: Data("hello".utf8))
        await drive.syncer.poll(recentInterval: 0, otherInterval: 0)

        #expect(try drive.store.child(of: folder.id, named: "from-a-peer.txt") != nil)
    }

    // MARK: F01

    /// The reproduced data loss: an edit waits through an outage, a peer saves, and a poll
    /// records the peer's version before our save runs.
    @Test func aPollBetweenAPeersSaveAndOursKeepsBothVersions() async throws {
        let drive = try Drive()
        let item = try await synced(drive, "/doc.txt", "version A")
        let base = try drive.base(of: item.id)

        await drive.server.put(path("/doc.txt"), content: Data("saved by a peer".utf8))
        try await drive.syncer.refresh(folderID: root)

        let outcome = try await drive.mutations.modify(
            id: item.id, baseVersion: base, newLocation: nil,
            contents: try drive.local("edited offline"), failOnConflict: false)

        #expect(outcome.shouldFetchContent)
        #expect(await drive.text(at: path("/doc.txt")) == "saved by a peer")
        #expect(await drive.text(at: path("/doc.txt (conflict)")) == "edited offline")
    }

    @Test func aStaleDeleteIsRefusedEvenAfterAPoll() async throws {
        let drive = try Drive()
        let item = try await synced(drive, "/doc.txt", "version A")
        let base = try drive.base(of: item.id)

        await drive.server.put(path("/doc.txt"), content: Data("saved by a peer".utf8))
        try await drive.syncer.refresh(folderID: root)

        await #expect(throws: RemoteError.versionMismatch(path("/doc.txt"))) {
            try await drive.mutations.delete(id: item.id, baseVersion: base)
        }
        #expect(await drive.text(at: path("/doc.txt")) == "saved by a peer")
    }

    @Test func anEditOfTheCurrentVersionReplacesIt() async throws {
        let drive = try Drive()
        let item = try await synced(drive, "/doc.txt", "version A")

        let outcome = try await drive.mutations.modify(
            id: item.id, baseVersion: try drive.base(of: item.id), newLocation: nil,
            contents: try drive.local("version B"), failOnConflict: false)

        #expect(!outcome.shouldFetchContent)
        #expect(await drive.text(at: path("/doc.txt")) == "version B")
        #expect(await drive.server.content(at: path("/doc.txt (conflict)")) == nil)
    }

    @Test func noAgreedVersionNeverReplacesAnExistingFile() async throws {
        let drive = try Drive()
        let item = try await synced(drive, "/doc.txt", "on the server")

        _ = try await drive.mutations.modify(
            id: item.id, baseVersion: nil, newLocation: nil,
            contents: try drive.local("local content"), failOnConflict: false)

        #expect(await drive.text(at: path("/doc.txt")) == "on the server")
        #expect(await drive.text(at: path("/doc.txt (conflict)")) == "local content")
    }

    @Test func failOnConflictLeavesEverythingForMacOSToMerge() async throws {
        let drive = try Drive()
        let item = try await synced(drive, "/doc.txt", "version A")
        let base = try drive.base(of: item.id)
        await drive.server.put(path("/doc.txt"), content: Data("saved by a peer".utf8))

        await #expect(throws: RemoteError.versionMismatch(path("/doc.txt"))) {
            _ = try await drive.mutations.modify(
                id: item.id, baseVersion: base, newLocation: nil,
                contents: try drive.local("ours"), failOnConflict: true)
        }
        #expect(await drive.server.content(at: path("/doc.txt (conflict)")) == nil)
    }

    // MARK: Third assessment

    /// macOS is told its file holds these bytes, so they have to be at the item's real path.
    @Test func aFolderMovedJustBeforeTheCommitIsFollowed() async throws {
        let drive = try Drive()
        await drive.server.put(path("/old/file.txt"), content: Data("before".utf8))
        try await drive.syncer.refresh(folderID: root)
        let parent = try #require(try drive.store.child(of: root, named: "old"))
        try await drive.syncer.refresh(folderID: parent.id)
        let file = try #require(try drive.store.child(of: parent.id, named: "file.txt"))
        let base = try drive.base(of: file.id)

        let store = drive.store
        let server = drive.server
        let parentID = parent.id
        let root = root
        let old = path("/old")
        let new = path("/new")
        await server.duringNextCommit {
            await server.rename(old, to: new)
            _ = try? store.recordMoved(id: parentID, to: root, name: "new")
        }
        let outcome = try await drive.mutations.modify(
            id: file.id, baseVersion: base, newLocation: nil,
            contents: try drive.local("after"), failOnConflict: false)

        #expect(try drive.store.path(of: outcome.item.id) == path("/new/file.txt"))
        #expect(await drive.text(at: path("/new/file.txt")) == "after")
        #expect(await drive.text(at: path("/old/file.txt")) == nil)
        #expect(!outcome.shouldFetchContent)
    }

    /// The folder is another item with the name, never a sign that the file is gone, which would
    /// have macOS delete it, edits and all.
    @Test func aFileMoveReplayNeverAdoptsAFolder() async throws {
        let drive = try Drive()
        let item = try await synced(drive, "/doc.txt", "version A")
        let base = try drive.base(of: item.id)
        await drive.server.remove(path("/doc.txt"))
        await drive.server.makeFolder(path("/unrelated"))

        for contents in [nil, try drive.local("edited")] {
            let taken = try await nameTaken {
                _ = try await drive.mutations.modify(
                    id: item.id, baseVersion: base, newLocation: (root, "unrelated"), contents: contents,
                    failOnConflict: false)
            }
            #expect(taken.holder?.name == "unrelated")
            #expect(taken.holder?.kind == .directory)
        }
    }

    @Test func aFolderMoveReplayIsStillRecognised() async throws {
        let drive = try Drive()
        await drive.server.makeFolder(path("/folder"))
        try await drive.syncer.refresh(folderID: root)
        let folder = try #require(try drive.store.child(of: root, named: "folder"))
        await drive.server.rename(path("/folder"), to: path("/renamed"))

        let outcome = try await drive.mutations.modify(
            id: folder.id, baseVersion: try drive.base(of: folder.id), newLocation: (root, "renamed"),
            contents: nil, failOnConflict: false)

        #expect(outcome.item.name == "renamed")
    }

    @Test func aShortDownloadIsFetchedAgain() async throws {
        let drive = try Drive()
        await drive.server.put(path("/doc.txt"), content: Data("the whole file".utf8))
        await drive.server.shortenDownloads(1)
        let target = drive.folder.appendingPathComponent("out")

        _ = try await drive.server.verifiedDownload(path("/doc.txt"), to: target)

        #expect(try Data(contentsOf: target) == Data("the whole file".utf8))
    }

    /// What the iPhone shows while a file comes down: each step as it starts, again on a retry.
    @Test func aDownloadSaysWhatItsDoing() async throws {
        let drive = try Drive()
        await drive.server.put(path("/doc.txt"), content: Data("the whole file".utf8))
        await drive.server.shortenDownloads(1)
        let target = drive.folder.appendingPathComponent("out")
        let seen = Mutex<[DownloadStage]>([])

        _ = try await drive.server.verifiedDownload(path("/doc.txt"), to: target) { stage in
            seen.withLock { $0.append(stage) }
        }

        #expect(seen.withLock { $0 } == [.checking, .downloading, .verifying, .checking, .downloading, .verifying])
    }

    @Test func aFileThatStaysShortIsRefusedAndNotLeftBehind() async throws {
        let drive = try Drive()
        await drive.server.put(path("/doc.txt"), content: Data("the whole file".utf8))
        await drive.server.shortenDownloads(2)
        let target = drive.folder.appendingPathComponent("out")

        await #expect(throws: (any Error).self) {
            _ = try await drive.server.verifiedDownload(path("/doc.txt"), to: target)
        }
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    @Test func aBusySaveAsksForARetry() async throws {
        let drive = try Drive()
        let item = try await synced(drive, "/doc.txt", "version A")
        await drive.server.fail(with: .locked(path("/doc.txt")))

        await #expect(throws: RemoteError.locked(path("/doc.txt"))) {
            _ = try await drive.mutations.modify(
                id: item.id, baseVersion: try drive.base(of: item.id), newLocation: nil,
                contents: try drive.local("edited"), failOnConflict: false)
        }

        #expect(try drive.store.takeBusyRetry(now: Date().addingTimeInterval(SyncStore.busyRetryDelay + 1)))
    }

    // MARK: During a recovery

    @Test func aChangeToAnItemARecoveryHasntReachedWaits() async throws {
        let drive = try Drive()
        try drive.store.setNeedsRebuild(true)

        await #expect(throws: SyncError.recovering) {
            _ = try await drive.mutations.modify(
                id: "unknown", baseVersion: "v", newLocation: nil, contents: nil, failOnConflict: false)
        }
        await #expect(throws: SyncError.recovering) {
            _ = try await drive.mutations.modify(
                id: "unknown", baseVersion: "v", newLocation: nil,
                contents: try drive.local("edited"), failOnConflict: false)
        }
    }

    @Test func aFileInAFolderARecoveryHasntReachedWaits() async throws {
        let drive = try Drive()
        try drive.store.setNeedsRebuild(true)

        await #expect(throws: SyncError.recovering) {
            _ = try await drive.mutations.create(
                name: "new.txt", parentID: "unknown", isFolder: false,
                contents: try drive.local("new"), mayAlreadyExist: false)
        }
    }

    /// Saying a delete is done would leave the file on the server, with macOS sure it's gone.
    @Test func aDeleteARecoveryCantPlaceWaits() async throws {
        let drive = try Drive()
        try drive.store.setNeedsRebuild(true)

        await #expect(throws: SyncError.recovering) {
            try await drive.mutations.delete(id: "unknown", baseVersion: "v")
        }
    }

    @Test func aReplayedDeleteOnASettledDriveIsDone() async throws {
        let drive = try Drive()
        try await drive.mutations.delete(id: "unknown", baseVersion: "v")
    }

    @Test func aChangeToAnUnknownItemOnASettledDriveSaysItsGone() async throws {
        let drive = try Drive()
        await #expect(throws: SyncError.itemNotFound("unknown")) {
            _ = try await drive.mutations.modify(
                id: "unknown", baseVersion: "v", newLocation: nil, contents: nil, failOnConflict: false)
        }
    }

    // MARK: Failed files

    /// macOS ignores an item whose version hasn't moved, so a pin would never reach it.
    @Test func aPinMovesTheMetadataVersionAndNotTheContent() async throws {
        let drive = try Drive()
        var item = try await synced(drive, "/doc.txt", "version A")
        let before = (ItemVersions.content(of: item), ItemVersions.metadata(of: item))
        item.isPinned = true
        #expect(ItemVersions.metadata(of: item) != before.1)
        #expect(ItemVersions.content(of: item) == before.0)
    }

    @Test func aFailureMovesTheMetadataVersionAndNotTheContent() async throws {
        let drive = try Drive()
        let item = try await synced(drive, "/doc.txt", "version A")
        #expect(ItemVersions.metadata(of: item, isFailed: true) != ItemVersions.metadata(of: item))
        #expect(ItemVersions.metadata(of: item, isFailed: true).count <= 128)
    }

    @Test func aDeleteTheServerRefusesIsListed() async throws {
        let drive = try Drive()
        let item = try await synced(drive, "/doc.txt", "version A")
        await drive.server.fail(with: .forbidden(path("/doc.txt")))

        await #expect(throws: RemoteError.forbidden(path("/doc.txt"))) {
            try await drive.mutations.delete(id: item.id, baseVersion: try drive.base(of: item.id))
        }
        #expect(try drive.store.failures().map(\.id) == [item.id])
    }

    /// A peer's newer version comes back by itself, so nothing here needs a person.
    @Test func aDeleteRefusedForAPeersVersionIsntAFailure() async throws {
        let drive = try Drive()
        let item = try await synced(drive, "/doc.txt", "version A")
        let base = try drive.base(of: item.id)
        await drive.server.put(path("/doc.txt"), content: Data("saved by a peer".utf8))

        await #expect(throws: RemoteError.versionMismatch(path("/doc.txt"))) {
            try await drive.mutations.delete(id: item.id, baseVersion: base)
        }
        #expect(try drive.store.failures().isEmpty)
    }

    @Test func aFullServerIsListedOnTheFile() async throws {
        let drive = try Drive()
        let item = try await synced(drive, "/doc.txt", "version A")
        await drive.server.fail(with: .insufficientStorage)

        await #expect(throws: RemoteError.insufficientStorage) {
            _ = try await drive.mutations.modify(
                id: item.id, baseVersion: try drive.base(of: item.id), newLocation: nil,
                contents: try drive.local("too much"), failOnConflict: false)
        }
        #expect(try drive.store.failures().map(\.id) == [item.id])
    }

    @Test func aSuccessfulDeleteClearsItsFailure() async throws {
        let drive = try Drive()
        let item = try await synced(drive, "/doc.txt", "version A")
        try drive.store.recordFailure(id: item.id, name: item.name, message: "Earlier")

        try await drive.mutations.delete(id: item.id, baseVersion: try drive.base(of: item.id))

        #expect(try drive.store.failures().isEmpty)
    }

    // MARK: Changes with no new content

    /// A tag, a date or a flag sends no bytes. If the answer named a peer's newer version with no
    /// fetch, macOS would label the old bytes on this Mac with it, and the next edit would pass
    /// as an edit of the peer's save and overwrite it.
    @Test func aTagChangeNeverLabelsOldBytesWithAPeersVersion() async throws {
        let drive = try Drive()
        let item = try await synced(drive, "/doc.txt", "version A")
        let base = try drive.base(of: item.id)
        await drive.server.put(path("/doc.txt"), content: Data("saved by a peer".utf8))

        let outcome = try await drive.mutations.modify(
            id: item.id, baseVersion: base, newLocation: nil, contents: nil, failOnConflict: false)

        // Either macOS still holds its own version, or it's told to fetch.
        let reported = String(decoding: ItemVersions.content(of: outcome.item), as: UTF8.self)
        #expect(reported == base || outcome.shouldFetchContent)

        // The edit that follows must not replace the peer's save.
        let baseOfNextEdit = outcome.shouldFetchContent ? base : reported
        _ = try await drive.mutations.modify(
            id: item.id, baseVersion: baseOfNextEdit, newLocation: nil,
            contents: try drive.local("edited from version A"), failOnConflict: false)
        #expect(await drive.text(at: path("/doc.txt")) == "saved by a peer")
        #expect(await drive.text(at: path("/doc.txt (conflict)")) == "edited from version A")
    }

    @Test func aTagChangeAfterAPollAsksMacOSToFetchThePeersVersion() async throws {
        let drive = try Drive()
        let item = try await synced(drive, "/doc.txt", "version A")
        let base = try drive.base(of: item.id)
        await drive.server.put(path("/doc.txt"), content: Data("saved by a peer".utf8))
        try await drive.syncer.refresh(folderID: root)

        let outcome = try await drive.mutations.modify(
            id: item.id, baseVersion: base, newLocation: nil, contents: nil, failOnConflict: false)

        #expect(outcome.shouldFetchContent)
    }

    @Test func aTagChangeOnTheCurrentVersionFetchesNothing() async throws {
        let drive = try Drive()
        let item = try await synced(drive, "/doc.txt", "version A")

        let outcome = try await drive.mutations.modify(
            id: item.id, baseVersion: try drive.base(of: item.id), newLocation: nil, contents: nil,
            failOnConflict: false)

        #expect(!outcome.shouldFetchContent)
    }

    /// These never reach the server, so an outage can't leave them waiting.
    @Test func aTagChangeWorksDuringAnOutage() async throws {
        let drive = try Drive()
        let item = try await synced(drive, "/doc.txt", "version A")
        await drive.server.fail(with: .unreachable("gone"))

        let outcome = try await drive.mutations.modify(
            id: item.id, baseVersion: try drive.base(of: item.id), newLocation: nil, contents: nil,
            failOnConflict: false)

        #expect(outcome.item.id == item.id)
    }

    /// A rename carries whatever the server has now, which may not be what's on this Mac.
    @Test func renamingAFileAPeerChangedFetchesTheirVersion() async throws {
        let drive = try Drive()
        let item = try await synced(drive, "/doc.txt", "version A")
        let base = try drive.base(of: item.id)
        await drive.server.put(path("/doc.txt"), content: Data("saved by a peer".utf8))

        let outcome = try await drive.mutations.modify(
            id: item.id, baseVersion: base, newLocation: (root, "renamed.txt"), contents: nil,
            failOnConflict: false)

        #expect(outcome.shouldFetchContent)
        #expect(await drive.text(at: path("/renamed.txt")) == "saved by a peer")
    }

    @Test func renamingTheCurrentVersionFetchesNothing() async throws {
        let drive = try Drive()
        let item = try await synced(drive, "/doc.txt", "version A")

        let outcome = try await drive.mutations.modify(
            id: item.id, baseVersion: try drive.base(of: item.id), newLocation: (root, "renamed.txt"),
            contents: nil, failOnConflict: false)

        #expect(!outcome.shouldFetchContent)
    }

    @Test func aServerWithNoVersionsNeverLosesAFile() async throws {
        let drive = try Drive()
        await drive.server.stopReportingVersions()
        let item = try await synced(drive, "/doc.txt", "on the server")

        _ = try await drive.mutations.modify(
            id: item.id, baseVersion: try drive.base(of: item.id), newLocation: nil,
            contents: try drive.local("ours"), failOnConflict: false)

        #expect(await drive.text(at: path("/doc.txt")) == "on the server")
        #expect(await drive.text(at: path("/doc.txt (conflict)")) == "ours")
    }

    // MARK: F04

    @Test func aReplayedCreateAdoptsItsOwnFile() async throws {
        let drive = try Drive()
        let source = try drive.local("new file")
        await drive.server.loseResponses()

        await #expect(throws: RemoteError.self) {
            _ = try await drive.mutations.create(
                name: "new.txt", parentID: root, isFolder: false, contents: source, mayAlreadyExist: false)
        }
        let saved = try await drive.mutations.create(
            name: "new.txt", parentID: root, isFolder: false, contents: source, mayAlreadyExist: false)

        #expect(saved.name == "new.txt")
        #expect(await drive.server.content(at: path("/new.txt (conflict)")) == nil)
    }

    @Test func aReplayedSaveAdoptsItsOwnVersion() async throws {
        let drive = try Drive()
        let item = try await synced(drive, "/doc.txt", "version A")
        let base = try drive.base(of: item.id)
        let edit = try drive.local("version B")
        await drive.server.loseResponses()

        await #expect(throws: RemoteError.self) {
            _ = try await drive.mutations.modify(
                id: item.id, baseVersion: base, newLocation: nil, contents: edit, failOnConflict: false)
        }
        let outcome = try await drive.mutations.modify(
            id: item.id, baseVersion: base, newLocation: nil, contents: edit, failOnConflict: false)

        #expect(!outcome.shouldFetchContent)
        #expect(await drive.server.content(at: path("/doc.txt (conflict)")) == nil)
    }

    @Test func aReplayedRenameFindsItAlreadyDone() async throws {
        let drive = try Drive()
        let item = try await synced(drive, "/old.txt", "content")
        await drive.server.loseResponses()

        await #expect(throws: RemoteError.self) {
            _ = try await drive.mutations.modify(
                id: item.id, baseVersion: item.versionID, newLocation: (root, "new.txt"),
                contents: nil, failOnConflict: false)
        }
        let outcome = try await drive.mutations.modify(
            id: item.id, baseVersion: item.versionID, newLocation: (root, "new.txt"),
            contents: nil, failOnConflict: false)

        #expect(outcome.item.name == "new.txt")
        #expect(outcome.item.id == item.id)
    }

    @Test func aReplayedDeleteIsHarmless() async throws {
        let drive = try Drive()
        let item = try await synced(drive, "/doc.txt", "content")
        let base = try drive.base(of: item.id)
        await drive.server.loseResponses()

        await #expect(throws: RemoteError.self) {
            try await drive.mutations.delete(id: item.id, baseVersion: base)
        }
        try await drive.mutations.delete(id: item.id, baseVersion: base)

        #expect(try drive.store.item(id: item.id) == nil)
    }

    // MARK: F06

    @Test func aFileChangingMidDownloadIsReadAgain() async throws {
        let drive = try Drive()
        let item = try await synced(drive, "/doc.txt", "version A")
        await drive.server.changeDuringNextDownload(path("/doc.txt"), content: Data("version B".utf8))
        let destination = drive.folder.appendingPathComponent("download")

        let saved = try await drive.mutations.fetch(id: item.id, to: destination)

        #expect(try String(contentsOf: destination, encoding: .utf8) == "version B")
        let server = try await drive.server.item(at: path("/doc.txt"))
        #expect(saved.versionID == server.versionID)
    }

    // MARK: Names and bookkeeping

    @Test func reservedNamesAreRefused() async throws {
        let drive = try Drive()
        let item = try await synced(drive, "/doc.txt", "content")

        await #expect(throws: RemoteError.reservedName(".cloudmount")) {
            _ = try await drive.mutations.create(
                name: ".cloudmount", parentID: root, isFolder: true, contents: nil, mayAlreadyExist: false)
        }
        await #expect(throws: RemoteError.reservedName(".cm-anything")) {
            _ = try await drive.mutations.modify(
                id: item.id, baseVersion: nil, newLocation: (root, ".cm-anything"),
                contents: nil, failOnConflict: false)
        }
    }

    @Test func aRenameAndAnEditTogetherKeepTheContent() async throws {
        let drive = try Drive()
        let item = try await synced(drive, "/old.txt", "version A")

        let outcome = try await drive.mutations.modify(
            id: item.id, baseVersion: try drive.base(of: item.id), newLocation: (root, "new.txt"),
            contents: try drive.local("version B"), failOnConflict: false)

        #expect(outcome.item.name == "new.txt")
        #expect(await drive.text(at: path("/new.txt")) == "version B")
    }

    @Test func aReadOnlyDriveRefusesEveryChange() async throws {
        let drive = try Drive()
        let item = try await synced(drive, "/doc.txt", "content")
        let readOnly = Mutations(
            backend: drive.server, store: drive.store, syncer: drive.syncer, isReadOnly: { true })

        await #expect(throws: RemoteError.readOnly) {
            _ = try await readOnly.create(
                name: "new", parentID: root, isFolder: true, contents: nil, mayAlreadyExist: false)
        }
        await #expect(throws: RemoteError.readOnly) {
            _ = try await readOnly.modify(
                id: item.id, baseVersion: nil, newLocation: (root, "renamed"),
                contents: nil, failOnConflict: false)
        }
        await #expect(throws: RemoteError.readOnly) {
            try await readOnly.delete(id: item.id, baseVersion: nil)
        }
        #expect(await drive.text(at: path("/doc.txt")) == "content")
    }

    @Test func aFailedFileIsListedAndASuccessClearsIt() async throws {
        let drive = try Drive()
        let item = try await synced(drive, "/doc.txt", "content")
        await drive.server.fail(with: .forbidden(path("/doc.txt")))

        await #expect(throws: RemoteError.self) {
            _ = try await drive.mutations.modify(
                id: item.id, baseVersion: try drive.base(of: item.id), newLocation: nil,
                contents: try drive.local("new"), failOnConflict: false)
        }
        #expect(try drive.store.failures().map(\.name) == ["doc.txt"])

        await drive.server.fail(with: nil)
        _ = try await drive.mutations.modify(
            id: item.id, baseVersion: try drive.base(of: item.id), newLocation: nil,
            contents: try drive.local("new"), failOnConflict: false)
        #expect(try drive.store.failures().isEmpty)
    }

    @Test func aConnectionProblemIsntListedOnEachFile() async throws {
        let drive = try Drive()
        let item = try await synced(drive, "/doc.txt", "content")
        await drive.server.fail(with: .unreachable("offline"))

        await #expect(throws: RemoteError.self) {
            _ = try await drive.mutations.modify(
                id: item.id, baseVersion: try drive.base(of: item.id), newLocation: nil,
                contents: try drive.local("new"), failOnConflict: false)
        }
        #expect(try drive.store.failures().isEmpty)
    }

    @Test func aPinnedFolderKeepsItsLocalCopies() async throws {
        let drive = try Drive()
        await drive.server.put(path("/kept/inside.txt"), content: Data("x".utf8))
        await drive.server.put(path("/loose.txt"), content: Data("y".utf8))
        try await drive.syncer.refresh(folderID: root)
        let folder = try #require(try drive.store.child(of: root, named: "kept"))
        try await drive.syncer.refresh(folderID: folder.id)
        let inside = try #require(try drive.store.child(of: folder.id, named: "inside.txt"))
        let loose = try #require(try drive.store.child(of: root, named: "loose.txt"))
        let old = Date(timeIntervalSince1970: 1_000_000_000)
        try drive.store.markLocal(id: inside.id, size: 1, now: old)
        try drive.store.markLocal(id: loose.id, size: 1, now: old)

        try drive.store.setPinned(id: folder.id, isPinned: true)

        #expect(try drive.store.copiesToRemove(idleFor: 60, sizeLimit: nil) == [loose.id])
        #expect(try drive.store.item(id: folder.id)?.isPinned == true)
    }

    @Test func aLocalCopyIsRecordedAfterASave() async throws {
        let drive = try Drive()
        _ = try await drive.mutations.create(
            name: "new.txt", parentID: root, isFolder: false,
            contents: try drive.local("12345"), mayAlreadyExist: false)

        #expect(try drive.store.localCopiesSize() == 5)
    }

    @Test func anItemBeingSavedIsNotRemovedByAListing() async throws {
        let drive = try Drive()
        let item = try await synced(drive, "/doc.txt", "content")
        let parent = try #require(try drive.store.item(id: root))
        let operation = try drive.store.beginOperation(item: item.id, kind: "modify")

        let removed = try drive.store.removeConfirmed(item, parentGeneration: parent.generation)
        #expect(!removed)

        try drive.store.finishOperation(id: operation)
        #expect(try drive.store.removeConfirmed(item, parentGeneration: parent.generation))
    }

    @Test func aRemovalChecksTheItemIsStillWhatWasObserved() async throws {
        let drive = try Drive()
        let item = try await synced(drive, "/doc.txt", "content")
        let parent = try #require(try drive.store.item(id: root))
        try drive.store.recordMoved(id: item.id, to: root, name: "renamed.txt")

        #expect(try !drive.store.removeConfirmed(item, parentGeneration: parent.generation))
        #expect(try drive.store.item(id: item.id) != nil)
    }
}

@Suite struct ItemVersionsTests {
    private func item(name: String, versionID: String?, kind: RemoteItem.Kind = .file) -> SyncItem {
        SyncItem(
            id: "id", parentID: UUID().uuidString, name: name, kind: kind, size: 1, modified: nil,
            version: "token", versionID: versionID, generation: 0)
    }

    @Test func componentsStayUnderApplesLimit() {
        let longName = String(repeating: "é", count: 500)
        let long = item(name: longName, versionID: String(repeating: "a", count: 64))
        #expect(ItemVersions.content(of: long).count <= 128)
        #expect(ItemVersions.metadata(of: long).count <= 128)
    }

    @Test func aRenameChangesOnlyTheMetadataVersion() {
        var first = item(name: "a.txt", versionID: "v1")
        let before = (ItemVersions.content(of: first), ItemVersions.metadata(of: first))
        first.name = "b.txt"
        #expect(ItemVersions.content(of: first) == before.0)
        #expect(ItemVersions.metadata(of: first) != before.1)
    }

    /// macOS only redraws a badge when the version changes, and a changed content version
    /// would make it download the file again.
    @Test func theUnavailableBadgeOnlyChangesTheMetadataVersion() throws {
        let item = SyncItem(
            id: "a", parentID: SyncItem.rootID, name: "a.txt", kind: .file, size: 1, modified: nil,
            version: "v1", versionID: "id", generation: 0)
        #expect(ItemVersions.metadata(of: item, isUnavailable: true) != ItemVersions.metadata(of: item))
        #expect(ItemVersions.metadata(of: item, isUnavailable: true).count <= 128)
    }

    @Test func theBaseVersionRoundTrips() {
        let content = ItemVersions.content(of: item(name: "a", versionID: "abc123"))
        #expect(ItemVersions.baseVersion(from: content, beforeFirstSync: Data([0])) == "abc123")
    }

    @Test func beforeFirstSyncMeansNoBase() {
        let marker = Data([1, 2, 3])
        #expect(ItemVersions.baseVersion(from: marker, beforeFirstSync: marker) == nil)
    }
}
