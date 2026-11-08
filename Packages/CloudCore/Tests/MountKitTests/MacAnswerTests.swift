// Apache 2 license - developer@infinitecontext.com

import CloudCore
import FakeRemote
import Foundation
import MountKit
import SyncCore
import Testing

/// What macOS is told when something fails. macOS acts on these with real files: it deletes on
/// "no such item", stops for good on "can't sync", and takes "leave out" as a person's delete.
@Suite struct MacAnswerTests {
    private let path = RemotePath("/Report.docx")!

    /// Every way a request can fail, so no case slips past these rules.
    private var everyFailure: [Error] {
        let remote: [RemoteError] = [
            .notFound(path), .alreadyExists(path), .parentMissing(path), .forbidden(path), .locked(path),
            .versionMismatch(path), .nameTooLong(path), .reservedName(".cloudmount"),
            .notAPlainFile(path, .folder), .notAPlainFile(path, .package), .notAPlainFile(path, .link),
            .notAPlainFile(path, .other), .unreadableHere(path, "No"), .readOnly, .failed(path, "No"),
            .tooSlow(path), .tooLarge(path), .tooManyItems(path), .cancelled, .unauthorized, .insufficientStorage,
            .unreachable("connection reset"), .server(status: 500), .server(status: 429),
            .vault(.wrongPassword), .vault(.retired), .hostKeyUnknown, .hostKeyChanged, .unsupportedServer("No"),
        ]
        let other: [Error] = [
            SyncError.itemNotFound("x"), SyncError.recovering, SyncError.held, SyncError.anchorExpired,
            NameTaken(path: path, holder: nil), CocoaError(.userCancelled), URLError(.badURL),
        ]
        return remote + other
    }

    private let everyRequest: [MacAnswer.Request] = [
        .read, .create(isSafelyNew: false), .create(isSafelyNew: true), .delete,
        .modify(hasContents: false, failOnConflict: false), .modify(hasContents: true, failOnConflict: false),
        .modify(hasContents: true, failOnConflict: true),
    ]

    /// macOS deletes its copy on "no such item", and an edit's bytes may exist nowhere else.
    @Test func anEditWithBytesIsNeverToldItsGone() {
        for error in everyFailure {
            for failOnConflict in [false, true] {
                let request = MacAnswer.Request.modify(hasContents: true, failOnConflict: failOnConflict)
                #expect(MacAnswer.to(request, failingWith: error) != .noSuchItem, "\(error)")
            }
        }
    }

    /// macOS answers "leave out" with a delete that reaches every device.
    @Test func onlyACreateOfSomethingNewIsEverLeftOut() {
        for request in everyRequest where request != .create(isSafelyNew: true) {
            for error in everyFailure {
                #expect(MacAnswer.to(request, failingWith: error) != .leaveOut, "\(request) \(error)")
            }
        }
        let new = MacAnswer.Request.create(isSafelyNew: true)
        #expect(MacAnswer.to(new, failingWith: RemoteError.nameTooLong(path)) == .leaveOut)
        #expect(MacAnswer.to(.create(isSafelyNew: false), failingWith: RemoteError.nameTooLong(path)) == .cannotSync)
        // A folder may be a package macOS hasn't flattened, so it waits where a person can see it.
        #expect(MacAnswer.to(new, failingWith: RemoteError.notAPlainFile(path, .folder)) == .cannotSync)
    }

    /// A refused rename onto a taken name has to reach macOS as exactly that, or it stops for good.
    @Test func aTakenNameIsSaidAsOne() {
        let holder = SyncItem(
            id: "theirs", parentID: SyncItem.rootID, name: "Report.docx", kind: .file, size: 1,
            modified: nil, version: "v", versionID: "v", generation: 0)
        for request in everyRequest where request != .delete {
            #expect(MacAnswer.to(request, failingWith: RemoteError.alreadyExists(path)) == .nameTaken(nil))
            #expect(
                MacAnswer.to(request, failingWith: NameTaken(path: path, holder: holder)) == .nameTaken(holder))
        }
    }

    @Test func eachRequestGetsWhatAppleAsksFor() {
        let modify = MacAnswer.Request.modify(hasContents: false, failOnConflict: false)
        #expect(MacAnswer.to(.delete, failingWith: SyncError.itemNotFound("x")) == .done)
        #expect(MacAnswer.to(.delete, failingWith: RemoteError.notFound(path)) == .done)
        #expect(MacAnswer.to(.delete, failingWith: RemoteError.versionMismatch(path)) == .deletionRefused)
        #expect(MacAnswer.to(.delete, failingWith: SyncError.recovering) == .tryLater)
        #expect(MacAnswer.to(.modify(hasContents: true, failOnConflict: true), failingWith: RemoteError.versionMismatch(path)) == .peerChanged)
        #expect(MacAnswer.to(modify, failingWith: RemoteError.notFound(path)) == .noSuchItem)
        #expect(MacAnswer.to(.read, failingWith: SyncError.itemNotFound("x")) == .noSuchItem)
        #expect(MacAnswer.to(.read, failingWith: SyncError.recovering) == .tryLater)
        #expect(MacAnswer.to(.read, failingWith: SyncError.anchorExpired) == .startOver)
        #expect(MacAnswer.to(modify, failingWith: SyncError.held) == .cannotSync)
        #expect(MacAnswer.to(modify, failingWith: RemoteError.unauthorized) == .signIn)
        #expect(MacAnswer.to(modify, failingWith: RemoteError.insufficientStorage) == .outOfSpace)
        #expect(MacAnswer.to(modify, failingWith: RemoteError.cancelled) == .cancelled)
        #expect(MacAnswer.to(modify, failingWith: CocoaError(.userCancelled)) == .asIs)
    }

    /// A read-only drive keeps everything, so a delete that reaches it is refused in the way that
    /// has the system put the item back. "Can't sync" would leave it gone here and there on the server.
    @Test func aReadOnlyDeleteBringsTheItemBack() {
        #expect(MacAnswer.to(.delete, failingWith: RemoteError.readOnly) == .deletionRefused)
        #expect(MacAnswer.to(.create(isSafelyNew: false), failingWith: RemoteError.readOnly) == .cannotSync)
        #expect(
            MacAnswer.to(.modify(hasContents: true, failOnConflict: false), failingWith: RemoteError.readOnly)
                == .cannotSync)
    }

    /// Swift's own cancellation is a cancel, not a broken item: "can't sync" would stop the system
    /// asking for that file again until it changed.
    @Test func aCancelledTaskIsACancel() {
        for request in everyRequest {
            #expect(MacAnswer.to(request, failingWith: CancellationError()) == .cancelled, "\(request)")
        }
    }

    /// A busy server comes back by itself, and "can't sync" would leave the file until it changed.
    @Test func aBusyServerMeansTryLater() {
        let modify = MacAnswer.Request.modify(hasContents: true, failOnConflict: false)
        #expect(MacAnswer.to(modify, failingWith: RemoteError.server(status: 429)) == .tryLater)
        #expect(MacAnswer.to(modify, failingWith: RemoteError.unreachable("timed out")) == .tryLater)
        #expect(RemoteError.server(status: 429).isRetryable)
        #expect(MacAnswer.to(modify, failingWith: RemoteError.tooLarge(path)) == .cannotSync)
        #expect(RemoteError.tooLarge(path).canHoldAFile)
    }

    /// A not-found while listing a folder, the drive's root included, never drops what's in it.
    @Test func oneNotFoundNeverEmptiesAFolder() {
        #expect(MacAnswer.listingShowsWhatsKnown(after: RemoteError.notFound(.root), knowsItems: false))
        #expect(MacAnswer.listingShowsWhatsKnown(after: RemoteError.notFound(path), knowsItems: true))
        #expect(MacAnswer.listingShowsWhatsKnown(after: RemoteError.unreachable("No"), knowsItems: true))
        #expect(!MacAnswer.listingShowsWhatsKnown(after: RemoteError.unreachable("No"), knowsItems: false))
        #expect(!MacAnswer.listingShowsWhatsKnown(after: SyncError.recovering, knowsItems: true))
    }
}

/// A call that carries bytes may hold the only copy of an edit, so it's never answered in a way
/// that has macOS delete them.
@Suite struct UnsentBytesTests {
    private let root = SyncItem.rootID

    private func path(_ text: String) -> RemotePath {
        RemotePath(text)!
    }

    private struct Drive {
        let server = FakeRemote()
        let store: SyncStore
        let syncer: Syncer
        let mutations: Mutations
        let folder: URL

        init() throws {
            folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("UnsentBytesTests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            store = try SyncStore(url: folder.appendingPathComponent("state.sqlite"))
            // Two passes with no wait, so a test can have a peer's delete confirmed here.
            var guards = Syncer.Guards()
            guards.minimumSpan = 0
            syncer = Syncer(store: store, backend: server, guards: guards)
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

        func base(of item: SyncItem) -> String {
            String(decoding: ItemVersions.content(of: item), as: UTF8.self)
        }

        func synced(_ location: String, _ text: String, in parentID: String = SyncItem.rootID) async throws -> SyncItem {
            let remote = RemotePath(location)!
            await server.put(remote, content: Data(text.utf8))
            try await syncer.refresh(folderID: parentID)
            return try #require(try store.child(of: parentID, named: remote.name))
        }

        /// A peer's delete, confirmed here by two direct checks before macOS has taken it in.
        func confirmGone(_ location: String, in parentID: String = SyncItem.rootID) async throws {
            await server.remove(RemotePath(location)!)
            try await syncer.refresh(folderID: parentID)
            try await syncer.refresh(folderID: parentID)
        }
    }

    /// macOS hands over an edit and a rename together, for a file a peer deleted.
    @Test func anEditAndARenameOfAFileAPeerDeletedArePutBack() async throws {
        let drive = try Drive()
        let item = try await drive.synced("/Report.docx", "version A")
        await drive.server.remove(path("/Report.docx"))

        let outcome = try await drive.mutations.modify(
            id: item.id, baseVersion: drive.base(of: item), newLocation: (root, "Final.docx"),
            contents: try drive.local("edited"), failOnConflict: false)

        #expect(outcome.item.id == item.id)
        #expect(outcome.item.name == "Final.docx")
        #expect(await drive.text(at: path("/Final.docx")) == "edited")
    }

    /// The same rename with no edit has no bytes to keep, so the file is gone.
    @Test func aRenameAloneOfAFileAPeerDeletedIsGone() async throws {
        let drive = try Drive()
        let item = try await drive.synced("/Report.docx", "version A")
        await drive.server.remove(path("/Report.docx"))

        await #expect(throws: RemoteError.self) {
            _ = try await drive.mutations.modify(
                id: item.id, baseVersion: drive.base(of: item), newLocation: (root, "Final.docx"),
                contents: nil, failOnConflict: false)
        }
        #expect(await drive.text(at: path("/Final.docx")) == nil)
    }

    /// The peer's delete was confirmed here before macOS took it in, and then the edit arrived.
    @Test func anEditOfAFileThisMacAlreadyRemovedIsPutBack() async throws {
        let drive = try Drive()
        let item = try await drive.synced("/Report.docx", "version A")
        let start = try drive.store.currentAnchor()
        try await drive.confirmGone("/Report.docx")
        #expect(try drive.store.item(id: item.id) == nil)

        let outcome = try await drive.mutations.modify(
            id: item.id, baseVersion: drive.base(of: item), newLocation: nil,
            contents: try drive.local("edited"), failOnConflict: false, shownAt: (root, "Report.docx"))

        #expect(outcome.item.id == item.id)
        #expect(await drive.text(at: path("/Report.docx")) == "edited")
        #expect(try drive.store.item(id: item.id)?.name == "Report.docx")
        // macOS may not have heard of the removal yet. Either way, it ends up hearing it exists.
        let changes = try drive.store.changes(since: start)
        #expect(changes.updated.map(\.id).contains(item.id))
        #expect(!changes.deleted.contains(item.id))
    }

    /// Its folder went too, so there's nowhere to put it back. It waits, listed with why.
    @Test func anEditWhoseFolderWentTooWaitsWhereAPersonCanSeeIt() async throws {
        let drive = try Drive()
        await drive.server.makeFolder(path("/Work"))
        try await drive.syncer.refresh(folderID: root)
        let work = try #require(try drive.store.child(of: root, named: "Work"))
        let item = try await drive.synced("/Work/Report.docx", "version A", in: work.id)
        try await drive.confirmGone("/Work")
        #expect(try drive.store.item(id: work.id) == nil)

        var thrown: Error?
        do {
            _ = try await drive.mutations.modify(
                id: item.id, baseVersion: drive.base(of: item), newLocation: nil,
                contents: try drive.local("edited"), failOnConflict: false, shownAt: (work.id, "Report.docx"))
        } catch {
            thrown = error
        }

        let error = try #require(thrown)
        #expect(MacAnswer.to(.modify(hasContents: true, failOnConflict: false), failingWith: error) == .cannotSync)
        #expect(try drive.store.failures().map(\.id) == [item.id])
    }

    // MARK: A taken name

    /// A peer made a file with this name, and this Mac hasn't listed it yet.
    @Test func aRenameOntoAPeersNewFileSaysWhichItemHasTheName() async throws {
        let drive = try Drive()
        let item = try await drive.synced("/Draft.docx", "mine")
        await drive.server.put(path("/Final.docx"), content: Data("theirs".utf8))

        let taken = try await nameTaken {
            _ = try await drive.mutations.modify(
                id: item.id, baseVersion: drive.base(of: item), newLocation: (root, "Final.docx"),
                contents: try drive.local("edited"), failOnConflict: false)
        }

        #expect(taken.holder?.name == "Final.docx")
        #expect(taken.holder?.id != item.id)
        #expect(await drive.text(at: path("/Final.docx")) == "theirs")
        #expect(await drive.text(at: path("/Draft.docx")) == "mine")
        #expect(try drive.store.item(id: item.id)?.name == "Draft.docx")
        // macOS normally renames one of them, but if it doesn't, a person can see why.
        #expect(try drive.store.failures().map(\.id) == [item.id])
    }

    // MARK: One not-found

    @Test func oneNotFoundDuringADownloadIsLookedAtAgain() async throws {
        let drive = try Drive()
        let item = try await drive.synced("/Report.docx", "version A")
        await drive.server.goMissingOnce(path("/Report.docx"))
        let target = drive.folder.appendingPathComponent("out")

        _ = try await drive.mutations.fetch(id: item.id, to: target)

        #expect(try Data(contentsOf: target) == Data("version A".utf8))
    }

    @Test func aFileThatsReallyGoneSaysSoOnlyOnASettledDrive() async throws {
        let drive = try Drive()
        let item = try await drive.synced("/Report.docx", "version A")
        await drive.server.remove(path("/Report.docx"))
        let target = drive.folder.appendingPathComponent("out")

        await #expect(throws: SyncError.itemNotFound(item.id)) {
            _ = try await drive.mutations.fetch(id: item.id, to: target)
        }
        try drive.store.setNeedsRebuild(true)
        await #expect(throws: SyncError.recovering) {
            _ = try await drive.mutations.fetch(id: item.id, to: target)
        }
    }

    /// A re-import of a file with no bytes only hears "gone" after two looks.
    @Test func aReimportLooksTwiceBeforeSayingAFileIsGone() async throws {
        let drive = try Drive()
        await drive.server.put(path("/Report.docx"), content: Data("version A".utf8))
        await drive.server.goMissingOnce(path("/Report.docx"))

        let adopted = try await drive.mutations.create(
            name: "Report.docx", parentID: root, isFolder: false, contents: nil, mayAlreadyExist: true)

        #expect(adopted.name == "Report.docx")
    }
}
