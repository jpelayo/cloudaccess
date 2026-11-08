// Apache 2 license - developer@infinitecontext.com

import CloudCore
import FakeRemote
import Foundation
import MountKit
import SyncCore
import Testing

/// A file's own dates and checksum, kept beside it on servers that allow it. None of it is ever
/// part of a version: writing details never changes the file.
@Suite struct FileDetailsTests {
    private let root = SyncItem.rootID
    private let modified = Date(timeIntervalSince1970: 1_551_694_530)
    private let created = Date(timeIntervalSince1970: 1_543_651_200)

    private struct Drive {
        let server = FakeRemote()
        let store: SyncStore
        let syncer: Syncer
        let mutations: Mutations
        let folder: URL

        init() throws {
            folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("FileDetailsTests-\(UUID().uuidString)")
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
    }

    @Test func aSaveTakesMacOSsDatesToTheServer() async throws {
        let drive = try Drive()
        let saved = try await drive.mutations.create(
            name: "report.txt", parentID: root, isFolder: false, contents: try drive.local("content"),
            mayAlreadyExist: false, details: FileDetails(modified: modified, created: created))
        let onServer = try await drive.server.item(at: RemotePath("/report.txt")!)
        #expect(onServer.ownModified == modified)
        #expect(onServer.created == created)
        #expect(onServer.checksum?.count == 64)
        #expect(saved.ownModified == modified)
        #expect(saved.created == created)
    }

    /// The creation date first recorded stays, whatever a later save says. A Mac that never had
    /// the file's details can report when it downloaded the file.
    @Test func anEditKeepsWhenTheFileWasCreated() async throws {
        let drive = try Drive()
        let first = try await drive.mutations.create(
            name: "kept.txt", parentID: root, isFolder: false, contents: try drive.local("one"),
            mayAlreadyExist: false, details: FileDetails(modified: modified, created: created))
        let base = try #require(String(data: ItemVersions.content(of: first), encoding: .utf8))
        let later = modified.addingTimeInterval(86_400)
        _ = try await drive.mutations.modify(
            id: first.id, baseVersion: base, newLocation: nil, contents: try drive.local("two"),
            failOnConflict: false,
            details: FileDetails(modified: later, created: later))
        let onServer = try await drive.server.item(at: RemotePath("/kept.txt")!)
        #expect(onServer.created == created)
        #expect(onServer.ownModified == later)
    }

    @Test func aFolderKeepsWhenItWasMade() async throws {
        let drive = try Drive()
        let folder = try await drive.mutations.create(
            name: "Projects", parentID: root, isFolder: true, contents: nil, mayAlreadyExist: false,
            details: FileDetails(created: created))
        #expect(folder.created == created)
        #expect(try await drive.server.item(at: RemotePath("/Projects")!).created == created)
    }

    /// Another tool writing over the file leaves details that no longer describe it. Only when the
    /// item was created still holds.
    @Test func anotherToolsWriteLeavesOnlyTheCreationDate() async throws {
        let drive = try Drive()
        _ = try await drive.mutations.create(
            name: "shared.txt", parentID: root, isFolder: false, contents: try drive.local("ours"),
            mayAlreadyExist: false, details: FileDetails(modified: modified, created: created))
        await drive.server.put(RemotePath("/shared.txt")!, content: Data("another tool's".utf8))
        try await drive.syncer.refresh(folderID: root)
        let row = try #require(try drive.store.child(of: root, named: "shared.txt"))
        #expect(row.ownModified == nil)
        #expect(row.checksum == nil)
        #expect(row.created == created)
    }

    /// Details that arrive after the bytes, as from a replayed save, change what macOS is told about
    /// the item, and not its content, so nothing downloads again.
    @Test func newDetailsAloneChangeNoContent() async throws {
        let drive = try Drive()
        await drive.server.put(RemotePath("/plain.txt")!, content: Data("bytes".utf8))
        try await drive.syncer.refresh(folderID: root)
        let before = try #require(try drive.store.child(of: root, named: "plain.txt"))
        await drive.server.addDetails(RemotePath("/plain.txt")!, FileDetails(modified: modified))
        try await drive.syncer.refresh(folderID: root)
        let after = try #require(try drive.store.child(of: root, named: "plain.txt"))
        #expect(after.ownModified == modified)
        #expect(after.version == before.version)
        #expect(ItemVersions.content(of: after) == ItemVersions.content(of: before))
        #expect(ItemVersions.metadata(of: after) != ItemVersions.metadata(of: before))
    }

    @Test func aServerThatKeepsNoDetailsSavesAsBefore() async throws {
        let drive = try Drive()
        await drive.server.refuseDetails()
        let saved = try await drive.mutations.create(
            name: "plain.txt", parentID: root, isFolder: false, contents: try drive.local("content"),
            mayAlreadyExist: false, details: FileDetails(modified: modified, created: created))
        #expect(saved.ownModified == nil)
        #expect(saved.created == nil)
        #expect(await drive.server.content(at: RemotePath("/plain.txt")!) == Data("content".utf8))
    }

    /// Writing details must never look like new content: a download would be retried, tombstones
    /// would stop matching, and listings would log changes that never happened.
    @Test func detailsAreNoPartOfAVersion() {
        let path = RemotePath("/file.txt")!
        let plain = RemoteItem(path: path, kind: .file, size: 5, modified: modified, versionID: "\"1\"")
        var described = plain
        described.ownModified = created
        described.created = created
        described.checksum = String(repeating: "a", count: 64)
        #expect(plain.versionToken == described.versionToken)
        #expect(described.shownModified == created)
        #expect(plain.shownModified == modified)
    }
}
