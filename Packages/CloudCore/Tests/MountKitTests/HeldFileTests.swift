// Apache 2 license - developer@infinitecontext.com

import CloudCore
import FakeRemote
import Foundation
import MountKit
import SyncCore
import Testing

/// macOS retries a failed file for as long as it takes, so nothing but this ever stops it, and a
/// spinner would turn for hours over a file that can't get through.
@Suite struct HeldFileTests {
    private let root = SyncItem.rootID

    private final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_000_000)

        func advance(minutes: Double) {
            now.addTimeInterval(minutes * 60)
        }
    }

    private struct Drive {
        let server = FakeRemote()
        let store: SyncStore
        let syncer: Syncer
        let mutations: Mutations
        let folder: URL
        let clock = Clock()

        init() throws {
            folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("HeldFileTests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            store = try SyncStore(url: folder.appendingPathComponent("state.sqlite"))
            syncer = Syncer(store: store, backend: server)
            let clock = clock
            mutations = Mutations(backend: server, store: store, syncer: syncer, clock: { clock.now })
        }

        func local(_ text: String) throws -> URL {
            let url = folder.appendingPathComponent(UUID().uuidString)
            try Data(text.utf8).write(to: url)
            return url
        }

        @discardableResult
        func tryToCreate(_ name: String) async throws -> SyncItem {
            try await mutations.create(
                name: name, parentID: SyncItem.rootID, isFolder: false, contents: try local("hello"),
                mayAlreadyExist: false)
        }

        /// Three failures, far enough apart to count.
        func hold(_ name: String) async throws {
            await server.fail(with: .server(status: 500))
            for _ in 1...3 {
                _ = try? await tryToCreate(name)
                clock.advance(minutes: 8)
            }
            await server.fail(with: nil)
        }
    }

    private func path(_ text: String) -> RemotePath {
        RemotePath(text)!
    }

    private func id(of name: String) -> String {
        SyncFailure.unsentID(name: name, parentID: root)
    }

    @Test func aFileThatKeepsFailingStopsBeingTried() async throws {
        let drive = try Drive()
        try await drive.hold("stuck.txt")

        #expect(try drive.store.isHeld(id: id(of: "stuck.txt")))
        await #expect(throws: SyncError.held) { try await drive.tryToCreate("stuck.txt") }
        #expect(await drive.server.content(at: path("/stuck.txt")) == nil)
    }

    @Test func aHeldFileIsListedWithItsReason() async throws {
        let drive = try Drive()
        try await drive.hold("stuck.txt")

        let failure = try #require(try drive.store.failures().first)
        #expect(failure.name == "stuck.txt")
        #expect(failure.message.contains("The server reported an error (500)."))
    }

    @Test func quickFailuresDontHoldAFile() async throws {
        let drive = try Drive()
        await drive.server.fail(with: .server(status: 500))
        for _ in 1...10 {
            _ = try? await drive.tryToCreate("busy.txt")
            drive.clock.advance(minutes: 0.5)
        }
        #expect(try !drive.store.isHeld(id: id(of: "busy.txt")))
    }

    @Test func twoFailuresFarApartDontHoldAFile() async throws {
        let drive = try Drive()
        await drive.server.fail(with: .server(status: 500))
        _ = try? await drive.tryToCreate("rare.txt")
        drive.clock.advance(minutes: 120)
        _ = try? await drive.tryToCreate("rare.txt")
        #expect(try !drive.store.isHeld(id: id(of: "rare.txt")))
    }

    /// Everything fails in an outage, and it all goes through once the server's back.
    @Test func anOutageNeverHoldsAFile() async throws {
        let drive = try Drive()
        try drive.store.setOffline(true, now: drive.clock.now)
        await drive.server.fail(with: .unreachable("gone"))
        for _ in 1...5 {
            try drive.store.setOffline(true, now: drive.clock.now)
            _ = try? await drive.tryToCreate("waiting.txt")
            drive.clock.advance(minutes: 8)
        }
        #expect(try !drive.store.isHeld(id: id(of: "waiting.txt")))
        #expect(try drive.store.attempts().isEmpty)
    }

    @Test func aProblemWithTheWholeDriveNeverHoldsAFile() async throws {
        let drive = try Drive()
        await drive.server.fail(with: .unauthorized)
        for _ in 1...5 {
            _ = try? await drive.tryToCreate("waiting.txt")
            drive.clock.advance(minutes: 8)
        }
        #expect(try !drive.store.isHeld(id: id(of: "waiting.txt")))
        #expect(try drive.store.attempts().isEmpty)
    }

    @Test func tryingAgainReleasesAHeldFile() async throws {
        let drive = try Drive()
        try await drive.hold("stuck.txt")

        try drive.store.clearAllFailures()
        try await drive.tryToCreate("stuck.txt")

        #expect(await drive.server.content(at: path("/stuck.txt")) != nil)
        #expect(try drive.store.failures().isEmpty)
        #expect(try drive.store.attempts().isEmpty)
    }

    /// Renaming is one way a person can help, and it needs nothing else from them.
    @Test func aRenamedFileIsAFreshStart() async throws {
        let drive = try Drive()
        try await drive.hold("stuck.txt")

        try await drive.tryToCreate("renamed.txt")

        #expect(await drive.server.content(at: path("/renamed.txt")) != nil)
    }

    @Test func aHeldEditIsNotSentUntilItsReleased() async throws {
        let drive = try Drive()
        await drive.server.put(path("/doc.txt"), content: Data("original".utf8))
        try await drive.syncer.refresh(folderID: root)
        let item = try #require(try drive.store.child(of: root, named: "doc.txt"))
        let base = String(decoding: ItemVersions.content(of: item), as: UTF8.self)

        func edit() async throws {
            _ = try await drive.mutations.modify(
                id: item.id, baseVersion: base, newLocation: nil,
                contents: try drive.local("edited"), failOnConflict: false)
        }
        await drive.server.fail(with: .server(status: 500))
        for _ in 1...3 {
            _ = try? await edit()
            drive.clock.advance(minutes: 8)
        }
        await drive.server.fail(with: nil)

        await #expect(throws: SyncError.held) { try await edit() }
        #expect(await drive.server.content(at: path("/doc.txt")) == Data("original".utf8))

        try drive.store.clearAllFailures()
        try await edit()
        #expect(await drive.server.content(at: path("/doc.txt")) == Data("edited".utf8))
    }

    /// A file already on the server keeps its identity through a rename, so nothing would start it
    /// afresh by itself, and a rename is a person dealing with it.
    @Test func renamingAHeldFileReleasesIt() async throws {
        let drive = try Drive()
        await drive.server.put(path("/doc.txt"), content: Data("original".utf8))
        try await drive.syncer.refresh(folderID: root)
        let item = try #require(try drive.store.child(of: root, named: "doc.txt"))
        let base = String(decoding: ItemVersions.content(of: item), as: UTF8.self)

        await drive.server.fail(with: .server(status: 500))
        for _ in 1...3 {
            _ = try? await drive.mutations.modify(
                id: item.id, baseVersion: base, newLocation: nil,
                contents: try drive.local("edited"), failOnConflict: false)
            drive.clock.advance(minutes: 8)
        }
        await drive.server.fail(with: nil)
        #expect(try drive.store.isHeld(id: item.id))

        _ = try await drive.mutations.modify(
            id: item.id, baseVersion: base, newLocation: (parentID: root, name: "renamed.txt"),
            contents: nil, failOnConflict: false)

        #expect(await drive.server.content(at: path("/renamed.txt")) != nil)
        #expect(try drive.store.attempts().isEmpty)
        #expect(try drive.store.failures().isEmpty)
    }

    /// What's on screen has to match what the person can see in Finder.
    @Test func aRenameThatFailsGoesByItsNewName() async throws {
        let drive = try Drive()
        await drive.server.put(path("/doc.txt"), content: Data("original".utf8))
        try await drive.syncer.refresh(folderID: root)
        let item = try #require(try drive.store.child(of: root, named: "doc.txt"))
        let base = String(decoding: ItemVersions.content(of: item), as: UTF8.self)

        await drive.server.fail(with: .server(status: 500))
        _ = try? await drive.mutations.modify(
            id: item.id, baseVersion: base, newLocation: (parentID: root, name: "renamed.txt"),
            contents: nil, failOnConflict: false)

        #expect(try drive.store.attempts().first?.name == "renamed.txt")
    }

    /// Nothing else stops a held edit, so the rename can't quietly release one.
    @Test func aHeldFileStaysHeldWithoutARename() async throws {
        let drive = try Drive()
        await drive.server.put(path("/doc.txt"), content: Data("original".utf8))
        try await drive.syncer.refresh(folderID: root)
        let item = try #require(try drive.store.child(of: root, named: "doc.txt"))
        let base = String(decoding: ItemVersions.content(of: item), as: UTF8.self)

        await drive.server.fail(with: .server(status: 500))
        for _ in 1...3 {
            _ = try? await drive.mutations.modify(
                id: item.id, baseVersion: base, newLocation: nil,
                contents: try drive.local("edited"), failOnConflict: false)
            drive.clock.advance(minutes: 8)
        }
        await drive.server.fail(with: nil)

        #expect(throws: SyncError.held) {
            try Mutations.checkMayTry(id: item.id, newName: nil, store: drive.store)
        }
        try Mutations.checkMayTry(id: item.id, newName: "renamed.txt", store: drive.store)
        #expect(try !drive.store.isHeld(id: item.id))
    }

    /// Deleting is a person dealing with the file, so nothing holds that back.
    @Test func aHeldFileCanStillBeDeleted() async throws {
        let drive = try Drive()
        await drive.server.put(path("/doc.txt"), content: Data("original".utf8))
        try await drive.syncer.refresh(folderID: root)
        let item = try #require(try drive.store.child(of: root, named: "doc.txt"))
        let base = String(decoding: ItemVersions.content(of: item), as: UTF8.self)

        await drive.server.fail(with: .server(status: 500))
        for _ in 1...3 {
            _ = try? await drive.mutations.modify(
                id: item.id, baseVersion: base, newLocation: nil,
                contents: try drive.local("edited"), failOnConflict: false)
            drive.clock.advance(minutes: 8)
        }
        await drive.server.fail(with: nil)
        #expect(try drive.store.isHeld(id: item.id))

        try await drive.mutations.delete(id: item.id, baseVersion: base)

        #expect(try drive.store.failures().isEmpty)
        #expect(try drive.store.attempts().isEmpty)
    }

    @Test func aSuccessForgetsEarlierFailures() async throws {
        let drive = try Drive()
        await drive.server.fail(with: .server(status: 500))
        _ = try? await drive.tryToCreate("doc.txt")
        #expect(try drive.store.attempts().count == 1)

        await drive.server.fail(with: nil)
        try await drive.tryToCreate("doc.txt")

        #expect(try drive.store.attempts().isEmpty)
    }

    /// The reason has to say what really happened, or a person has nothing to go on.
    @Test func anAttemptSaysWhatTheServerSaid() async throws {
        let drive = try Drive()
        await drive.server.fail(with: .unreachable("connection reset by peer"))
        _ = try? await drive.tryToCreate("doc.txt")

        let attempt = try #require(try drive.store.attempts().first)
        #expect(attempt.name == "doc.txt")
        #expect(attempt.count == 1)
        #expect(attempt.message.contains("connection reset by peer"))
    }

    /// macOS finishing its import fixes this by itself, so it's shown and never held.
    @Test func aDriveBeingCheckedShowsButNeverHolds() async throws {
        let drive = try Drive()
        try drive.store.setNeedsRebuild(true)
        for _ in 1...5 {
            _ = try? await drive.mutations.create(
                name: "doc.txt", parentID: "not-known-yet", isFolder: false,
                contents: try drive.local("hello"), mayAlreadyExist: false)
            drive.clock.advance(minutes: 8)
        }
        let attempt = try #require(try drive.store.attempts().first)
        #expect(attempt.count == 5)
        #expect(!attempt.isHeld)
    }

    /// Connecting comes before everything here, and all the waiting files share it. It failing
    /// used to leave no trace, so they sat at "syncing" with nothing to say why.
    @Test func aFailureToConnectIsRecordedOnTheFile() throws {
        let drive = try Drive()
        Mutations.note(
            failure: RemoteError.unreachable("no route to host"), id: id(of: "doc.txt"), name: "doc.txt",
            store: drive.store, now: drive.clock.now)

        let attempt = try #require(try drive.store.attempts().first)
        #expect(attempt.name == "doc.txt")
        #expect(attempt.message.contains("no route to host"))
    }

    /// The extension refuses to connect while the app says the drive's offline. That's an outage.
    @Test func beingOfflineIsntAFailureOfTheFile() throws {
        let drive = try Drive()
        try drive.store.setOffline(true, now: drive.clock.now)
        Mutations.note(
            failure: RemoteError.unreachable("The drive is offline."), id: id(of: "doc.txt"), name: "doc.txt",
            store: drive.store, now: drive.clock.now)
        #expect(try drive.store.attempts().isEmpty)
    }

    @Test func aFailingFileKnowsWhereItIs() async throws {
        let drive = try Drive()
        await drive.server.fail(with: .server(status: 500))
        _ = try? await drive.tryToCreate("doc.txt")
        let attempt = try #require(try drive.store.attempts().first)
        #expect(drive.store.path(of: attempt) == path("/doc.txt"))
    }

    // MARK: Looking before sending

    private func tryToCreate(_ drive: Drive, _ name: String, from contents: URL) async throws {
        _ = try await drive.mutations.create(
            name: name, parentID: root, isFolder: false, contents: contents, mayAlreadyExist: false)
    }

    private func makePackage(_ drive: Drive) throws -> URL {
        let package = drive.folder.appendingPathComponent("\(UUID().uuidString).numbers")
        try FileManager.default.createDirectory(
            at: package.appendingPathComponent("Data"), withIntermediateDirectories: true)
        try Data("inside".utf8).write(to: package.appendingPathComponent("Index.zip"))
        return package
    }

    /// The real failure: macOS handed over a Numbers package, and it was sent as if it were a file.
    /// With Apple's flag this shouldn't arrive at all, and if it does it waits, and says why.
    @Test func aFolderHandedOverAsAFileIsNeverSent() async throws {
        let drive = try Drive()
        let package = try makePackage(drive)

        await #expect(throws: RemoteError.self) {
            try await tryToCreate(drive, "comparativa.numbers", from: package)
        }

        #expect(await drive.server.stagesStarted == 0)
        #expect(await drive.server.content(at: path("/comparativa.numbers")) == nil)
        let failure = try #require(try drive.store.failures().first)
        #expect(FileProblem(stored: failure.message).cause.contains("nothing was sent"))
    }

    @Test func aFlattenedPackageGoesLikeAnyFile() async throws {
        let drive = try Drive()
        try await tryToCreate(drive, "comparativa.numbers.pkgf", from: try drive.local("flattened"))
        #expect(await drive.server.content(at: path("/comparativa.numbers.pkgf")) == Data("flattened".utf8))
    }

    /// Bringing one back hasn't been proved yet, so nothing removes it to save space.
    @Test func aFlattenedPackageIsNeverRemovedToSaveSpace() async throws {
        let drive = try Drive()
        let item = try await drive.mutations.create(
            name: "doc.numbers.pkgf", parentID: root, isFolder: false, contents: try drive.local("flattened"),
            mayAlreadyExist: false)
        try drive.store.markLocal(id: item.id, size: 100)
        #expect(try drive.store.copiesToRemove(idleFor: 0, sizeLimit: 0).isEmpty)
    }

    /// Saving over it would leave a flat conflict copy beside it, once for every edit.
    @Test func aFolderOnTheServerIsntSavedOver() async throws {
        let drive = try Drive()
        await drive.server.makeFolder(path("/Tool.app"))
        try await drive.syncer.refresh(folderID: root)
        let item = try #require(try drive.store.child(of: root, named: "Tool.app"))

        await #expect(throws: RemoteError.self) {
            _ = try await drive.mutations.modify(
                id: item.id, baseVersion: nil, newLocation: nil, contents: try drive.local("flat"),
                failOnConflict: false)
        }

        #expect(await drive.server.stagesStarted == 0)
    }

    /// Asking for a folder's content must never come back as "no such item".
    @Test func aFolderOnTheServerIsntFetchedAsAFile() async throws {
        let drive = try Drive()
        await drive.server.makeFolder(path("/Tool.app"))
        try await drive.syncer.refresh(folderID: root)
        let item = try #require(try drive.store.child(of: root, named: "Tool.app"))

        await #expect(throws: RemoteError.failed(path("/Tool.app"), "This is a folder on the server, so it can't be downloaded as one file.")) {
            _ = try await drive.mutations.fetch(
                id: item.id, to: drive.folder.appendingPathComponent(UUID().uuidString))
        }
    }

    /// Nothing can be saved under a name the server can't hold, so the upload doesn't start.
    @Test func aNameThatCantGoIsRefusedBeforeUploading() async throws {
        let drive = try Drive()
        await drive.server.limitNames(to: 10)

        await #expect(throws: RemoteError.self) { try await drive.tryToCreate("a very long name.txt") }

        #expect(await drive.server.stagesStarted == 0)
    }

    @Test func aLinkIsNeverSent() async throws {
        let drive = try Drive()
        let link = drive.folder.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: try drive.local("real"))

        await #expect(throws: RemoteError.self) { try await tryToCreate(drive, "link.txt", from: link) }

        #expect(await drive.server.stagedCount == 0)
    }

    @Test func aFileThatCantBeReadIsntBlamedOnTheServer() async throws {
        let drive = try Drive()
        let source = try drive.local("private")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: source.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: source.path) }

        await #expect(throws: RemoteError.self) { try await tryToCreate(drive, "doc.txt", from: source) }

        let attempt = try #require(try drive.store.attempts().first)
        #expect(attempt.message.contains("This Mac couldn't read the file"))
        #expect(await drive.server.stagedCount == 0)
    }

    /// macOS would be told a file was saved that's a mix of two versions.
    @Test func aFileThatChangesWhileBeingSentIsntSaved() async throws {
        let drive = try Drive()
        let source = try drive.local("the first version")
        await drive.server.duringNextStage {
            try? Data("something much longer than before".utf8).write(to: source)
        }

        await #expect(throws: RemoteError.self) { try await tryToCreate(drive, "doc.txt", from: source) }

        #expect(await drive.server.content(at: path("/doc.txt")) == nil)
        #expect(await drive.server.stagedCount == 0)
    }

    @Test func aPlainFileStillGoes() async throws {
        let drive = try Drive()
        try await tryToCreate(drive, "doc.txt", from: try drive.local("hello"))
        #expect(await drive.server.content(at: path("/doc.txt")) == Data("hello".utf8))
    }

    @Test func anEmptyFileStillGoes() async throws {
        let drive = try Drive()
        try await tryToCreate(drive, "empty.txt", from: try drive.local(""))
        #expect(await drive.server.content(at: path("/empty.txt")) == Data())
    }

    // MARK: What's been done

    @Test func anUploadIsRecorded() async throws {
        let drive = try Drive()
        try await drive.tryToCreate("doc.txt")

        let entry = try #require(try drive.store.recentActivity().first)
        #expect(entry.kind == .uploaded)
        #expect(entry.name == "doc.txt")
        #expect(entry.size == 5)
        #expect(try drive.store.totals().uploaded == 1)
    }

    @Test func aDownloadIsRecorded() async throws {
        let drive = try Drive()
        await drive.server.put(path("/doc.txt"), content: Data("hello".utf8))
        try await drive.syncer.refresh(folderID: root)
        let item = try #require(try drive.store.child(of: root, named: "doc.txt"))

        _ = try await drive.mutations.fetch(
            id: item.id, to: drive.folder.appendingPathComponent(UUID().uuidString))

        #expect(try drive.store.recentActivity().first?.kind == .downloaded)
        #expect(try drive.store.totals().downloaded == 1)
    }

    @Test func aFailureIsNotRecordedAsDone() async throws {
        let drive = try Drive()
        await drive.server.fail(with: .server(status: 500))
        _ = try? await drive.tryToCreate("doc.txt")
        #expect(try drive.store.recentActivity().isEmpty)
        #expect(try drive.store.totals().uploaded == 0)
    }
}
