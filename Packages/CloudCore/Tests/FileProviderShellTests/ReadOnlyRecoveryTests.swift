// Apache 2 license - developer@infinitecontext.com

import CloudCore
import FakeRemote
import FileProviderShell
import Foundation
import SyncCore
import Testing

/// Only the Mac app finishes a recovery, and the iPhone app can't reach the extension's database.
/// Without this, a damaged database on the iPhone left the drive empty in Files for good.
@Suite struct ReadOnlyRecoveryTests {
    private func damagedStore() throws -> SyncStore {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReadOnlyRecoveryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("drive.sqlite")
        try Data(repeating: 0xAB, count: 16_384).write(to: url)
        let opened = try SyncStore.opening(url: url, backup: folder.appendingPathComponent("drive.backup"))
        #expect(opened.recovery == .startedAgain)
        return opened.store
    }

    @Test func aDamagedDatabaseFinishesItsOwnRecovery() async throws {
        let store = try damagedStore()
        let server = FakeRemote()
        await server.put(RemotePath("/Report.docx")!, content: Data("report".utf8))
        await server.makeFolder(RemotePath("/Photos")!)
        let epoch = try store.currentAnchor().epoch

        let finished = try await ReadOnlyRecovery.finishIfNeeded(store: store, syncer: Syncer(store: store, backend: server))

        #expect(finished)
        #expect(try !store.needsRebuild())
        // A new epoch is what has the system list the whole drive again.
        #expect(try store.currentAnchor().epoch != epoch)
        #expect(try Set(store.children(of: SyncItem.rootID).map(\.name)) == ["Report.docx", "Photos"])
    }

    /// With no server, nothing is finished, and the next check tries again.
    @Test func anUnreachableServerLeavesItForNextTime() async throws {
        let store = try damagedStore()
        let server = FakeRemote()
        await server.fail(with: .unreachable("offline"))

        await #expect(throws: RemoteError.self) {
            try await ReadOnlyRecovery.finishIfNeeded(store: store, syncer: Syncer(store: store, backend: server))
        }
        #expect(try store.needsRebuild())
    }

    @Test func aHealthyDatabaseIsLeftAlone() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReadOnlyRecoveryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = try SyncStore(url: folder.appendingPathComponent("drive.sqlite"))
        let epoch = try store.currentAnchor().epoch
        let finished = try await ReadOnlyRecovery.finishIfNeeded(store: store, syncer: Syncer(store: store, backend: FakeRemote()))
        #expect(!finished)
        #expect(try store.currentAnchor().epoch == epoch)
    }
}
