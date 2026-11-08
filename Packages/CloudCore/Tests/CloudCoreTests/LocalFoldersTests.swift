// Apache 2 license - developer@infinitecontext.com

import CloudCore
import Foundation
import Testing

@Suite struct LocalFoldersTests {
    private func tree(_ folders: [String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        for folder in folders {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// macOS processes a folder's direct children, so a parent has to come before what's in it.
    @Test func nearestFoldersComeFirst() throws {
        let root = try tree(["a/b/c", "d"])
        let found = LocalFolders.under(root, limit: 100).map(\.lastPathComponent)

        #expect(found.first == root.lastPathComponent)
        #expect(found.count == 5)
        let parent = try #require(found.firstIndex(of: "a"))
        let child = try #require(found.firstIndex(of: "b"))
        #expect(parent < child)
    }

    @Test func filesAreLeftOut() throws {
        let root = try tree(["a"])
        try Data("x".utf8).write(to: root.appendingPathComponent("a/file.txt"))

        #expect(LocalFolders.under(root, limit: 100).count == 2)
    }

    /// A link could lead out of the drive, or back into it forever.
    @Test func linksArentFollowed() throws {
        let root = try tree(["a"])
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("a/loop"), withDestinationURL: root)

        #expect(LocalFolders.under(root, limit: 100).count == 2)
    }

    @Test func aHugeTreeStopsAtTheLimit() throws {
        let root = try tree(["a", "b", "c", "d", "e"])
        #expect(LocalFolders.under(root, limit: 3).count == 3)
    }

    @Test func aMissingRootIsHarmless() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(LocalFolders.under(missing, limit: 10) == [missing])
    }
}
