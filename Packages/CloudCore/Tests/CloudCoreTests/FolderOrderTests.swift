// Apache 2 license - developer@infinitecontext.com

import CloudCore
import Foundation
import Testing

/// How the iPhone lists a folder. Folders go on top only when the person asks for that, and
/// anything the server didn't give a size or a date for goes last, whichever way the list runs.
@Suite struct FolderOrderTests {
    private func file(_ name: String, size: Int64? = nil, modified: TimeInterval? = nil) -> RemoteItem {
        RemoteItem(
            path: RemotePath("/\(name)")!, kind: .file, size: size,
            modified: modified.map { Date(timeIntervalSince1970: $0) })
    }

    private func folder(_ name: String, size: Int64? = nil, modified: TimeInterval? = nil) -> RemoteItem {
        RemoteItem(
            path: RemotePath("/\(name)")!, kind: .directory, size: size,
            modified: modified.map { Date(timeIntervalSince1970: $0) })
    }

    private func names(_ items: [RemoteItem], _ order: FolderOrder, foldersFirst: Bool) -> [String] {
        order.sorted(items, foldersFirst: foldersFirst).map(\.path.name)
    }

    // With folders on top

    @Test func namesReadLikeFinder() {
        let items = [file("Informe 10.pdf"), file("informe 2.pdf"), folder("Zeta"), file("árbol.txt"), folder("alfa")]
        #expect(names(items, .nameAscending, foldersFirst: true)
            == ["alfa", "Zeta", "árbol.txt", "informe 2.pdf", "Informe 10.pdf"])
        #expect(names(items, .nameDescending, foldersFirst: true)
            == ["Zeta", "alfa", "Informe 10.pdf", "informe 2.pdf", "árbol.txt"])
    }

    @Test func byModified() {
        let items = [file("b", modified: 200), file("a", modified: 100), file("c"), folder("f", modified: 50)]
        #expect(names(items, .modifiedOldest, foldersFirst: true) == ["f", "a", "b", "c"])
        #expect(names(items, .modifiedNewest, foldersFirst: true) == ["f", "b", "a", "c"])
    }

    @Test func bySize() {
        let items = [file("small", size: 10), file("big", size: 9_000), file("unknown"), folder("b"), folder("a")]
        #expect(names(items, .sizeLargest, foldersFirst: true) == ["a", "b", "big", "small", "unknown"])
        #expect(names(items, .sizeSmallest, foldersFirst: true) == ["a", "b", "small", "big", "unknown"])
    }

    @Test func byKindTheSameTypesSitTogether() {
        let items = [file("z.mov"), file("a.txt"), file("b.MOV"), file("README"), folder("docs")]
        #expect(names(items, .kind, foldersFirst: true) == ["docs", "b.MOV", "z.mov", "a.txt", "README"])
    }

    /// Two items alike in what's sorted on keep one order, so a list doesn't shuffle as it refreshes.
    @Test func tiesFallBackToTheName() {
        let items = [file("b", size: 5), file("a", size: 5)]
        #expect(names(items, .sizeLargest, foldersFirst: true) == ["a", "b"])
        #expect(names(items, .sizeSmallest, foldersFirst: true) == ["a", "b"])
    }

    // With folders among the files

    @Test func namesMixFoldersAndFiles() {
        let items = [file("b.txt"), folder("c"), folder("a"), file("D.pdf")]
        #expect(names(items, .nameAscending, foldersFirst: false) == ["a", "b.txt", "c", "D.pdf"])
        #expect(names(items, .nameDescending, foldersFirst: false) == ["D.pdf", "c", "b.txt", "a"])
    }

    @Test func datesMixFoldersAndFiles() {
        let items = [file("b", modified: 200), folder("f", modified: 150), file("a", modified: 100), file("c")]
        #expect(names(items, .modifiedOldest, foldersFirst: false) == ["a", "f", "b", "c"])
        #expect(names(items, .modifiedNewest, foldersFirst: false) == ["b", "f", "a", "c"])
    }

    /// A folder has no size of its own, even when a server reports one, so it goes with the files
    /// whose size isn't known.
    @Test func foldersGoAfterTheFilesWithASize() {
        let items = [file("small", size: 10), folder("b", size: 0), file("big", size: 9_000), file("unknown"), folder("a")]
        #expect(names(items, .sizeLargest, foldersFirst: false) == ["big", "small", "a", "b", "unknown"])
        #expect(names(items, .sizeSmallest, foldersFirst: false) == ["small", "big", "a", "b", "unknown"])
    }

    /// Folders are a kind of their own, so Kind keeps them together, by name, whatever the dots in
    /// their names.
    @Test func kindKeepsFoldersTogether() {
        let items = [file("z.mov"), folder("z.a"), file("a.txt"), folder("b")]
        #expect(names(items, .kind, foldersFirst: false) == ["b", "z.a", "z.mov", "a.txt"])
        #expect(names(items, .kind, foldersFirst: true) == ["b", "z.a", "z.mov", "a.txt"])
    }

    // File details

    private func described(_ name: String, own: TimeInterval?, created: TimeInterval?, server: TimeInterval) -> RemoteItem {
        RemoteItem(
            path: RemotePath("/\(name)")!, kind: .file, size: 1,
            modified: Date(timeIntervalSince1970: server),
            ownModified: own.map { Date(timeIntervalSince1970: $0) },
            created: created.map { Date(timeIntervalSince1970: $0) })
    }

    /// A file's own date, from its details, wins over when the server received it.
    @Test func modifiedUsesTheFilesOwnDate() {
        let items = [
            described("uploaded-last-but-old", own: 100, created: nil, server: 900),
            described("no-details", own: nil, created: nil, server: 500),
            described("recent", own: 800, created: nil, server: 200),
        ]
        #expect(names(items, .modifiedNewest, foldersFirst: false) == ["recent", "no-details", "uploaded-last-but-old"])
        #expect(names(items, .modifiedOldest, foldersFirst: false) == ["uploaded-last-but-old", "no-details", "recent"])
    }

    /// Only details say when something was created, so whatever has none goes last either way.
    @Test func byCreation() {
        let items = [
            described("b", own: nil, created: 200, server: 1),
            described("unknown", own: nil, created: nil, server: 1),
            described("a", own: nil, created: 100, server: 1),
        ]
        #expect(names(items, .createdNewest, foldersFirst: false) == ["b", "a", "unknown"])
        #expect(names(items, .createdOldest, foldersFirst: false) == ["a", "b", "unknown"])
    }

    // Hidden files

    @Test func hiddenFilesShowOnlyWhenAskedFor() {
        let items = [file(".env"), folder(".git"), file("a.txt"), folder("b")]
        #expect(FolderOrder.shown(items, showsHidden: false).map(\.path.name) == ["a.txt", "b"])
        #expect(FolderOrder.shown(items, showsHidden: true).map(\.path.name) == [".env", ".git", "a.txt", "b"])
    }

    /// What the drive keeps for itself isn't the person's, even with hidden files shown.
    @Test func theDrivesOwnItemsNeverShow() {
        let items = [folder(".cloudmount"), file(".cm-upload-1"), file(".profile")]
        #expect(FolderOrder.shown(items, showsHidden: true).map(\.path.name) == [".profile"])
    }

    @Test func everyOrderHasAName() {
        #expect(Set(FolderOrder.allCases.map(\.title)).count == FolderOrder.allCases.count)
    }
}
