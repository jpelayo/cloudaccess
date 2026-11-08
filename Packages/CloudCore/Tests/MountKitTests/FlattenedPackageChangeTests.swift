// Apache 2 license - developer@infinitecontext.com

import CloudCore
import FakeRemote
import Foundation
import MountKit
import SyncCore
import Testing

/// macOS keeps a package on a drive as `Report.numbers.pkgf` and on the disk as `Report.numbers`.
/// What's on the server is flattened, so it has to keep saying so, or it comes back as a plain
/// file nothing can open.
@Suite struct FlattenedPackageChangeTests {
    private let root = SyncItem.rootID

    private struct Drive {
        let server = FakeRemote()
        let store: SyncStore
        let syncer: Syncer
        let mutations: Mutations
        let folder: URL

        init() throws {
            folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("FlattenedPackageChangeTests-\(UUID().uuidString)")
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

        @discardableResult
        func create(_ name: String, _ text: String = "flattened") async throws -> SyncItem {
            try await mutations.create(
                name: name, parentID: SyncItem.rootID, isFolder: false, contents: try local(text),
                mayAlreadyExist: false)
        }

        func rename(
            _ item: SyncItem, to name: String, in parentID: String = SyncItem.rootID
        ) async throws -> Mutations.Outcome {
            try await mutations.modify(
                id: item.id, baseVersion: String(decoding: ItemVersions.content(of: item), as: UTF8.self),
                newLocation: (parentID: parentID, name: name), contents: nil, failOnConflict: false)
        }

        func onServer(_ location: String) async -> Data? {
            await server.content(at: RemotePath(location)!)
        }
    }

    private func path(_ text: String) -> RemotePath {
        RemotePath(text)!
    }

    // MARK: Renames

    @Test func aRenameWithTheSuffixGoesAsAsked() async throws {
        let drive = try Drive()
        let item = try await drive.create("Report.numbers.pkgf")

        let outcome = try await drive.rename(item, to: "Budget.numbers.pkgf")

        #expect(outcome.item.name == "Budget.numbers.pkgf")
        #expect(await drive.onServer("/Budget.numbers.pkgf") == Data("flattened".utf8))
    }

    @Test func aRenameWithoutTheSuffixKeepsIt() async throws {
        let drive = try Drive()
        let item = try await drive.create("Report.numbers.pkgf")

        let outcome = try await drive.rename(item, to: "Budget.numbers")

        #expect(outcome.item.name == "Budget.numbers.pkgf")
        #expect(await drive.onServer("/Budget.numbers.pkgf") == Data("flattened".utf8))
        #expect(await drive.onServer("/Budget.numbers") == nil)
    }

    /// The disk's name for it, so nothing has changed and the server isn't asked to move it.
    @Test func theNameOnTheDiskIsntARename() async throws {
        let drive = try Drive()
        let item = try await drive.create("Report.numbers.pkgf")

        let outcome = try await drive.rename(item, to: "Report.numbers")

        #expect(outcome.item.name == "Report.numbers.pkgf")
        #expect(await drive.onServer("/Report.numbers.pkgf") == Data("flattened".utf8))
        #expect(try drive.store.failures().isEmpty)
    }

    @Test func aMoveKeepsTheSuffix() async throws {
        let drive = try Drive()
        await drive.server.makeFolder(path("/Work"))
        try await drive.syncer.refresh(folderID: root)
        let work = try #require(try drive.store.child(of: root, named: "Work"))
        let item = try await drive.create("Report.numbers.pkgf")

        _ = try await drive.rename(item, to: "Report.numbers", in: work.id)

        #expect(await drive.onServer("/Work/Report.numbers.pkgf") == Data("flattened".utf8))
        #expect(await drive.onServer("/Report.numbers.pkgf") == nil)
    }

    /// A `.numbers` document can also be one plain file, and it must never gain the suffix.
    @Test func aPlainDocumentStaysPlain() async throws {
        let drive = try Drive()
        let item = try await drive.create("Report.numbers", "plain")

        let outcome = try await drive.rename(item, to: "Budget.numbers")

        #expect(outcome.item.name == "Budget.numbers")
        #expect(await drive.onServer("/Budget.numbers") == Data("plain".utf8))
    }

    // MARK: Editing and reading

    @Test func anEditReplacesTheFlattenedFile() async throws {
        let drive = try Drive()
        let item = try await drive.create("Report.numbers.pkgf")

        let outcome = try await drive.mutations.modify(
            id: item.id, baseVersion: String(decoding: ItemVersions.content(of: item), as: UTF8.self),
            newLocation: nil, contents: try drive.local("edited"), failOnConflict: false)

        #expect(outcome.item.name == "Report.numbers.pkgf")
        #expect(await drive.onServer("/Report.numbers.pkgf") == Data("edited".utf8))
    }

    @Test func itComesBackByteForByte() async throws {
        let drive = try Drive()
        let item = try await drive.create("Report.numbers.pkgf")
        let destination = drive.folder.appendingPathComponent("fetched")

        _ = try await drive.mutations.fetch(id: item.id, to: destination)

        #expect(try Data(contentsOf: destination) == Data("flattened".utf8))
    }

    // MARK: One place on the disk

    @Test func aPackageCantArriveBesideAFileWithItsName() async throws {
        let drive = try Drive()
        await drive.server.put(path("/Report.numbers"), content: Data("plain".utf8))
        try await drive.syncer.refresh(folderID: root)

        let taken = try await nameTaken {
            try await drive.create("Report.numbers.pkgf")
        }

        #expect(taken.path == path("/Report.numbers"))
        #expect(taken.holder?.name == "Report.numbers")
        #expect(await drive.server.stagesStarted == 0)
        #expect(await drive.onServer("/Report.numbers") == Data("plain".utf8))
    }

    @Test func aPackageCantArriveBesideAFolderWithItsName() async throws {
        let drive = try Drive()
        await drive.server.makeFolder(path("/Report.numbers"))
        try await drive.syncer.refresh(folderID: root)

        let taken = try await nameTaken {
            try await drive.create("Report.numbers.pkgf")
        }
        #expect(taken.holder?.kind == .directory)
    }

    @Test func aFileCantArriveBesideAPackageWithItsName() async throws {
        let drive = try Drive()
        try await drive.create("Report.numbers.pkgf")

        let taken = try await nameTaken {
            try await drive.create("Report.numbers", "plain")
        }
        #expect(taken.path == path("/Report.numbers.pkgf"))

        #expect(await drive.onServer("/Report.numbers") == nil)
    }

    @Test func aRenameCantLandBesideATwin() async throws {
        let drive = try Drive()
        await drive.server.put(path("/Report.numbers"), content: Data("plain".utf8))
        try await drive.syncer.refresh(folderID: root)
        let item = try await drive.create("Other.numbers.pkgf")

        let taken = try await nameTaken {
            _ = try await drive.rename(item, to: "Report.numbers")
        }
        #expect(taken.holder?.name == "Report.numbers")

        #expect(await drive.onServer("/Other.numbers.pkgf") == Data("flattened".utf8))
        #expect(try drive.store.item(id: item.id)?.name == "Other.numbers.pkgf")
    }

    /// macOS only flattens files, so this one is on the disk under the name it has.
    @Test func aFolderWithThatEndingHasNoTwin() async throws {
        let drive = try Drive()
        await drive.server.makeFolder(path("/Stuff.pkgf"))
        try await drive.syncer.refresh(folderID: root)

        try await drive.create("Stuff", "plain")

        #expect(await drive.onServer("/Stuff") == Data("plain".utf8))

        let made = try await drive.mutations.create(
            name: "Other.pkgf", parentID: root, isFolder: true, contents: nil, mayAlreadyExist: false)
        #expect(made.kind == .directory)
    }

    /// macOS answers with another name, so a row here would stay long after that worked.
    @Test func aTwinIsNothingForAPersonToDealWith() async throws {
        let drive = try Drive()
        await drive.server.put(path("/Report.numbers"), content: Data("plain".utf8))
        try await drive.syncer.refresh(folderID: root)

        _ = try? await drive.create("Report.numbers.pkgf")

        #expect(try drive.store.failures().isEmpty)
        #expect(try drive.store.attempts().isEmpty)
    }

    /// A re-import names something that's already there.
    @Test func aReimportFindsItsOwnItem() async throws {
        let drive = try Drive()
        let item = try await drive.create("Report.numbers.pkgf")

        let found = try await drive.mutations.create(
            name: "Report.numbers.pkgf", parentID: root, isFolder: false, contents: nil, mayAlreadyExist: true)

        #expect(found.id == item.id)
    }

    // MARK: Failures from before

    /// Before Apple's flag the same document failed as a folder, under its name on the disk. That
    /// name stays on the disk, so nothing else would ever clear it.
    @Test func goingClearsTheFailureFromBeforeItWasFlattened() async throws {
        let drive = try Drive()
        let earlier = SyncFailure.unsentID(name: "Report.numbers", parentID: root)
        try drive.store.noteFailedAttempt(id: earlier, name: "Report.numbers", message: "No", canHold: true)
        try drive.store.recordFailure(id: earlier, name: "Report.numbers", message: "No")

        try await drive.create("Report.numbers.pkgf")

        #expect(try drive.store.attempts().isEmpty)
        #expect(try drive.store.failures().isEmpty)
    }

    @Test func anEarlierHoldDoesntStopThePackage() async throws {
        let drive = try Drive()
        let earlier = SyncFailure.unsentID(name: "Report.numbers", parentID: root)
        for minutes in [0.0, 10, 20] {
            try drive.store.noteFailedAttempt(
                id: earlier, name: "Report.numbers", message: "No", canHold: true,
                now: Date().addingTimeInterval(minutes * 60))
        }
        #expect(try drive.store.isHeld(id: earlier))

        try await drive.create("Report.numbers.pkgf")

        #expect(await drive.onServer("/Report.numbers.pkgf") == Data("flattened".utf8))
    }

    /// macOS delivering the same rename again isn't a person helping, whichever name it uses.
    @Test func aHeldRenameStaysHeldUnderEitherName() async throws {
        let drive = try Drive()
        let item = try await drive.create("Report.numbers.pkgf")
        for minutes in [0.0, 10, 20] {
            try drive.store.noteFailedAttempt(
                id: item.id, name: "Stuck.numbers.pkgf", message: "No", canHold: true,
                now: Date().addingTimeInterval(minutes * 60))
        }

        #expect(throws: SyncError.held) {
            try Mutations.checkMayTry(id: item.id, newName: "Stuck.numbers", store: drive.store)
        }
        #expect(throws: SyncError.held) {
            try Mutations.checkMayTry(id: item.id, newName: "Stuck.numbers.pkgf", store: drive.store)
        }
        try Mutations.checkMayTry(id: item.id, newName: "Short.numbers", store: drive.store)
        #expect(try !drive.store.isHeld(id: item.id))
    }
}
