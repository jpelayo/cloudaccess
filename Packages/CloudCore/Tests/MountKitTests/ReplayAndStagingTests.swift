// Apache 2 license - developer@infinitecontext.com

import CloudCore
import FakeRemote
import Foundation
import MountKit
import SyncCore
import Testing

// These came from the second assessment.

@Suite struct ReplayAndStagingTests {
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
    }

    /// A file inside a folder, known to the database, with macOS's base version for it.
    private func fileInFolder(_ drive: Drive) async throws -> (folder: SyncItem, file: SyncItem, base: String?) {
        await drive.server.put(path("/old/file.txt"), content: Data("before".utf8))
        try await drive.syncer.refresh(folderID: root)
        let folder = try #require(try drive.store.child(of: root, named: "old"))
        try await drive.syncer.refresh(folderID: folder.id)
        let file = try #require(try drive.store.child(of: folder.id, named: "file.txt"))
        return (folder, file, file.versionID)
    }

    // MARK: R08

    @Test func aFolderMovedDuringAnUploadIsFollowed() async throws {
        let drive = try Drive()
        let (folder, file, base) = try await fileInFolder(drive)
        let contents = try drive.local("after")

        let mutations = drive.mutations
        let root = root
        await drive.server.duringNextStage {
            _ = try? await mutations.modify(
                id: folder.id, baseVersion: nil, newLocation: (root, "new"), contents: nil,
                failOnConflict: false)
        }
        _ = try await drive.mutations.modify(
            id: file.id, baseVersion: base, newLocation: nil, contents: contents, failOnConflict: false)

        #expect(await drive.text(at: path("/new/file.txt")) == "after")
        #expect(await drive.text(at: path("/old/file.txt")) == nil)
        #expect(try drive.store.path(of: file.id) == path("/new/file.txt"))
        #expect(await drive.server.stagedCount == 0)
    }

    @Test func aPeerDeletingTheFolderDuringAnUploadStillKeepsTheEdit() async throws {
        let drive = try Drive()
        let (_, file, base) = try await fileInFolder(drive)
        let contents = try drive.local("after")

        let server = drive.server
        let gone = path("/old")
        await drive.server.duringNextStage { await server.remove(gone) }
        _ = try await drive.mutations.modify(
            id: file.id, baseVersion: base, newLocation: nil, contents: contents, failOnConflict: false)

        #expect(await drive.text(at: path("/old/file.txt")) == "after")
    }

    @Test func aStagedUploadIsClearedWhenTheItemHasGone() async throws {
        let drive = try Drive()
        let (_, file, base) = try await fileInFolder(drive)
        let contents = try drive.local("after")

        let store = drive.store
        let id = file.id
        await drive.server.duringNextStage { try? store.recordDeleted(id: id) }
        await #expect(throws: (any Error).self) {
            _ = try await drive.mutations.modify(
                id: file.id, baseVersion: base, newLocation: nil, contents: contents, failOnConflict: false)
        }

        #expect(await drive.server.stagedCount == 0)
    }

    // MARK: R07

    @Test func aMoveReplayDoesntAdoptAPeersFile() async throws {
        let drive = try Drive()
        await drive.server.put(path("/a.txt"), content: Data("mine".utf8))
        await drive.server.put(path("/b.txt"), content: Data("somebody else's".utf8))
        try await drive.syncer.refresh(folderID: root)
        let file = try #require(try drive.store.child(of: root, named: "a.txt"))

        // A peer removed the source, and the destination is an unrelated file.
        await drive.server.remove(path("/a.txt"))
        await #expect(throws: (any Error).self) {
            _ = try await drive.mutations.modify(
                id: file.id, baseVersion: file.versionID, newLocation: (root, "b.txt"), contents: nil,
                failOnConflict: false)
        }

        #expect(try drive.store.child(of: root, named: "a.txt")?.id == file.id)
        #expect(await drive.text(at: path("/b.txt")) == "somebody else's")
    }

    @Test func aMoveReplayAdoptsItsOwnResult() async throws {
        let drive = try Drive()
        await drive.server.put(path("/a.txt"), content: Data("mine".utf8))
        try await drive.syncer.refresh(folderID: root)
        let file = try #require(try drive.store.child(of: root, named: "a.txt"))

        // The move reached the server, and its answer was lost.
        await drive.server.loseResponses()
        await #expect(throws: (any Error).self) {
            _ = try await drive.mutations.modify(
                id: file.id, baseVersion: file.versionID, newLocation: (root, "b.txt"), contents: nil,
                failOnConflict: false)
        }
        let outcome = try await drive.mutations.modify(
            id: file.id, baseVersion: file.versionID, newLocation: (root, "b.txt"), contents: nil,
            failOnConflict: false)

        #expect(outcome.item.id == file.id)
        #expect(outcome.item.name == "b.txt")
    }

    // MARK: Verified downloads

    @Test func aDownloadThatChangesPartWayIsFetchedAgain() async throws {
        let server = FakeRemote()
        await server.put(path("/a.txt"), content: Data("one".utf8))
        await server.changeDuringNextDownload(path("/a.txt"), content: Data("two".utf8))
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

        let item = try await server.verifiedDownload(path("/a.txt"), to: destination)

        #expect(try Data(contentsOf: destination) == Data("two".utf8))
        #expect(item.size == 3)
    }
}

@Suite struct TaskTrackerTests {
    @Test func finishedTasksArentKept() async {
        let tracker = TaskTracker()
        var tasks: [Task<Void, Never>] = []
        for _ in 0..<5_000 {
            tasks.append(tracker.run {})
        }
        for task in tasks {
            await task.value
        }
        // A task forgets itself just after its work ends, so give the last ones a moment.
        for _ in 0..<100 where tracker.count > 0 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(tracker.count == 0)
    }

    @Test func invalidatingCancelsWhatsRunning() async {
        let tracker = TaskTracker()
        let task = tracker.run {
            try? await Task.sleep(for: .seconds(60))
        }
        tracker.invalidate()
        await task.value
        #expect(task.isCancelled)
    }

    @Test func nothingNewRunsAfterInvalidating() async {
        let tracker = TaskTracker()
        tracker.invalidate()
        let task = tracker.run {}
        await task.value
        #expect(task.isCancelled)
    }
}
