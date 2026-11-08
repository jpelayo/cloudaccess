// Apache 2 license - developer@infinitecontext.com

import CloudCore
import FakeRemote
import Foundation
import MountKit
import SyncCore
import Testing

/// Telling macOS to leave something out of sync makes it call `deleteItem`, which can't be told
/// from a person's delete. Done to a file on the server, that takes the file away from every
/// device. So nothing that could be on the server can ever be left out.
@Suite struct ExclusionTests {
    private let root = SyncItem.rootID

    private struct Drive {
        let server = FakeRemote()
        let store: SyncStore
        let syncer: Syncer
        let mutations: Mutations
        let folder: URL

        init() throws {
            folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("ExclusionTests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            store = try SyncStore(url: folder.appendingPathComponent("state.sqlite"))
            syncer = Syncer(store: store, backend: server)
            mutations = Mutations(backend: server, store: store, syncer: syncer)
        }

        func synced(_ location: String, _ text: String = "on the server") async throws -> SyncItem {
            let target = RemotePath(location)!
            await server.put(target, content: Data(text.utf8))
            try await syncer.refresh(folderID: SyncItem.rootID)
            return try #require(try store.child(of: SyncItem.rootID, named: target.name))
        }

        func isSafelyNew(id: String = "__fp_new", name: String, hasOptions: Bool = false) -> Bool {
            Mutations.isSafelyNew(
                id: id, name: name, parentID: SyncItem.rootID, hasOptions: hasOptions, store: store)
        }
    }

    private func path(_ text: String) -> RemotePath {
        RemotePath(text)!
    }

    // MARK: What can be left out

    @Test func aNewFileCanBeLeftOut() throws {
        #expect(try Drive().isSafelyNew(name: ".DS_Store"))
    }

    @Test func aKnownItemCanNeverBeLeftOut() async throws {
        let drive = try Drive()
        let item = try await drive.synced("/doc.txt")
        #expect(!drive.isSafelyNew(id: item.id, name: "anything else"))
    }

    @Test func aNameAlreadyInTheFolderCanNeverBeLeftOut() async throws {
        let drive = try Drive()
        _ = try await drive.synced("/doc.txt")
        #expect(!drive.isSafelyNew(name: "doc.txt"))
    }

    /// A re-import and a conflicting delete both carry options, and an identifier that proves nothing.
    @Test func anythingWithOptionsCanNeverBeLeftOut() throws {
        #expect(try !Drive().isSafelyNew(name: ".DS_Store", hasOptions: true))
    }

    /// An empty database knows nothing, and that says nothing about the server.
    @Test func aDriveBeingRebuiltLeavesNothingOut() throws {
        let drive = try Drive()
        try drive.store.setNeedsRebuild(true)
        #expect(!drive.isSafelyNew(name: ".DS_Store"))
    }

    // MARK: What macOS offers again

    @Test func somethingOnTheServerIsAdopted() async throws {
        let drive = try Drive()
        await drive.server.put(path("/.DS_Store"), content: Data("left by a peer".utf8))

        let answer = await drive.mutations.settleLocalOnly(
            id: "__fp_new", name: ".DS_Store", parentID: root, mayAdopt: true)

        guard case .adopted(let item) = answer else {
            Issue.record("Expected it to be adopted, got \(answer)")
            return
        }
        #expect(item.name == ".DS_Store")
        #expect(await drive.server.content(at: path("/.DS_Store")) == Data("left by a peer".utf8))
    }

    @Test func somethingNotOnTheServerIsLeftOut() async throws {
        let drive = try Drive()
        let answer = await drive.mutations.settleLocalOnly(
            id: "__fp_new", name: ".DS_Store", parentID: root, mayAdopt: true)
        #expect(answer == .leaveOut)
    }

    /// A failed request says nothing about what's there.
    @Test func aNetworkFailureDecidesNothing() async throws {
        let drive = try Drive()
        await drive.server.fail(with: .unreachable("gone"))
        let answer = await drive.mutations.settleLocalOnly(
            id: "__fp_new", name: ".DS_Store", parentID: root, mayAdopt: true)
        #expect(answer == .tryLater)
    }

    @Test func aDriveBeingRebuiltDecidesNothing() async throws {
        let drive = try Drive()
        try drive.store.setNeedsRebuild(true)
        let answer = await drive.mutations.settleLocalOnly(
            id: "__fp_new", name: ".DS_Store", parentID: root, mayAdopt: true)
        #expect(answer == .tryLater)
    }

    /// A link has no place in the item model, so what's on the server can't stand in for it.
    @Test func aLinkIsntAdoptedAsAFile() async throws {
        let drive = try Drive()
        await drive.server.put(path("/link"), content: Data("a file".utf8))
        let answer = await drive.mutations.settleLocalOnly(
            id: "__fp_new", name: "link", parentID: root, mayAdopt: false)
        #expect(answer == .tryLater)
    }

    // MARK: Re-imports

    /// macOS drops its copy on "no such item", so a network failure must never become one.
    @Test func aNetworkFailureDuringAReimportIsntNoSuchItem() async throws {
        let drive = try Drive()
        await drive.server.fail(with: .unreachable("gone"))

        await #expect(throws: RemoteError.unreachable("gone")) {
            _ = try await drive.mutations.create(
                name: "doc.txt", parentID: root, isFolder: false, contents: nil, mayAlreadyExist: true)
        }
    }

    @Test func aMissingFileDuringARecoveryIsntGone() async throws {
        let drive = try Drive()
        try drive.store.setNeedsRebuild(true)

        await #expect(throws: SyncError.recovering) {
            _ = try await drive.mutations.create(
                name: "doc.txt", parentID: root, isFolder: false, contents: nil, mayAlreadyExist: true)
        }
    }

    // MARK: Renames

    /// The real risk: this used to answer with an exclusion, and macOS would then delete the file.
    @Test func aRenameToAnImpossibleNameLeavesTheFileWhereItIs() async throws {
        let drive = try Drive()
        let item = try await drive.synced("/doc.txt")
        let base = String(decoding: ItemVersions.content(of: item), as: UTF8.self)
        await drive.server.limitNames(to: 10)

        await #expect(throws: RemoteError.nameTooLong(path("/a name that's far too long.txt"))) {
            _ = try await drive.mutations.modify(
                id: item.id, baseVersion: base,
                newLocation: (parentID: root, name: "a name that's far too long.txt"),
                contents: nil, failOnConflict: false)
        }

        #expect(await drive.server.content(at: path("/doc.txt")) == Data("on the server".utf8))
        #expect(try drive.store.item(id: item.id)?.name == "doc.txt")
        #expect(try !drive.store.failures().isEmpty)
        #expect(!drive.isSafelyNew(id: item.id, name: "a name that's far too long.txt"))
    }

    /// macOS delivering the same rename again isn't a person helping.
    @Test func aHeldRenameStaysHeldUntilTheNameChanges() async throws {
        let drive = try Drive()
        let name = "a name that's far too long.txt"
        try drive.store.noteFailedAttempt(id: "item", name: name, message: "No", canHold: true)
        try drive.store.noteFailedAttempt(
            id: "item", name: name, message: "No", canHold: true, now: Date().addingTimeInterval(600))
        try drive.store.noteFailedAttempt(
            id: "item", name: name, message: "No", canHold: true, now: Date().addingTimeInterval(1_200))
        #expect(try drive.store.isHeld(id: "item"))

        #expect(throws: SyncError.held) {
            try Mutations.checkMayTry(id: "item", newName: name, store: drive.store)
        }
        try Mutations.checkMayTry(id: "item", newName: "short.txt", store: drive.store)
        #expect(try !drive.store.isHeld(id: "item"))
    }

    // MARK: What can never be sent

    @Test func onlyWhatCanNeverGoIsEverConsideredForLeavingOut() {
        let target = path("/doc.txt")
        #expect(RemoteError.nameTooLong(target).canNeverBeSent)
        #expect(RemoteError.reservedName(".cloudmount").canNeverBeSent)
        #expect(RemoteError.notAPlainFile(target, .link).canNeverBeSent)
        #expect(RemoteError.notAPlainFile(target, .other).canNeverBeSent)
        // A folder may only be a package macOS hasn't flattened, and that's for a person to see.
        #expect(!RemoteError.notAPlainFile(target, .folder).canNeverBeSent)
        #expect(!RemoteError.notAPlainFile(target, .package).canNeverBeSent)
        #expect(!RemoteError.forbidden(target).canNeverBeSent)
    }
}
