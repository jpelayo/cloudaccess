// Apache 2 license - developer@infinitecontext.com

import Foundation
import SyncCore
import Testing

/// Recents, tags and favourites on the iPhone come from what a provider keeps and hands back. Others
/// that dropped them lost files from Recents and favourites from the sidebar.
@Suite struct ItemMarksTests {
    private func store() throws -> SyncStore {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ItemMarksTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try SyncStore(url: folder.appendingPathComponent("state.sqlite"))
    }

    @Test func marksComeBackAsTheyWereGiven() throws {
        let store = try store()
        let tags = Data([0x62, 0x70, 0x6C, 0x69, 0x73, 0x74])
        let marks = ItemMarks(lastUsed: Date(timeIntervalSince1970: 1_800_000_000), tags: tags, favoriteRank: 42)
        try store.setMarks(marks, id: "item")
        #expect(try store.marks(id: "item") == marks)
        #expect(try store.marks(id: "other") == nil)
    }

    @Test func clearedMarksLeaveNothingBehind() throws {
        let store = try store()
        try store.setMarks(ItemMarks(favoriteRank: 1), id: "item")
        try store.setMarks(ItemMarks(), id: "item")
        #expect(try store.marks(id: "item") == nil)
    }

    /// A field the system didn't send stays, and one it sent as nothing is removed: that's how a
    /// tag or a favourite is taken off.
    @Test func onlyWhatTheSystemSentChanges() {
        let tags = Data([1, 2, 3])
        let start = ItemMarks(lastUsed: Date(timeIntervalSince1970: 100), tags: tags, favoriteRank: 7)
        #expect(start.applying(favoriteRank: .some(nil)) == ItemMarks(lastUsed: start.lastUsed, tags: tags))
        #expect(start.applying(tags: .some(nil)).favoriteRank == 7)
        #expect(start.applying() == start)
    }

    /// An older date arriving late mustn't push a file down Recents.
    @Test func aLastUsedDateOnlyMovesForward() {
        let start = ItemMarks(lastUsed: Date(timeIntervalSince1970: 200))
        #expect(start.applying(lastUsed: .some(Date(timeIntervalSince1970: 100))).lastUsed == start.lastUsed)
        #expect(start.applying(lastUsed: .some(Date(timeIntervalSince1970: 300))).lastUsed
            == Date(timeIntervalSince1970: 300))
    }

    /// A favourite set before the extension stopped is still there when it starts again.
    @Test func marksSurviveReopening() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ItemMarksTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("state.sqlite")
        try SyncStore(url: url).setMarks(ItemMarks(favoriteRank: 3), id: "item")
        #expect(try SyncStore(url: url).marks(id: "item")?.favoriteRank == 3)
    }
}
