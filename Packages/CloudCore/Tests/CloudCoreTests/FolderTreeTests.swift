// Apache 2 license - developer@infinitecontext.com

import Foundation
import Synchronization
import Testing
@testable import CloudCore

/// A server's folders as a picker sees them, held in memory.
private final class Folders: Sendable {
    private let made = Mutex<[RemotePath]>([])
    private let tree: [RemotePath: [RemoteItem]]

    init() {
        func folder(_ path: String) -> RemoteItem {
            RemoteItem(path: RemotePath(path)!, kind: .directory)
        }
        func file(_ path: String) -> RemoteItem {
            RemoteItem(path: RemotePath(path)!, kind: .file)
        }
        tree = [
            .root: [folder("Photos"), folder(".cloudmount"), file("notes.txt"), folder("documents"), folder("Archive 10"), folder("Archive 9")],
            RemotePath("Photos")!: [folder("Photos/2026"), file("Photos/a.jpg")],
            RemotePath("Photos/2026")!: [],
        ]
    }

    var created: [RemotePath] {
        made.withLock { $0 }
    }

    func list(_ path: RemotePath) throws -> [RemoteItem] {
        guard let items = tree[path] else { throw RemoteError.notFound(path) }
        return items + made.withLock { $0 }.filter { $0.parent == path }.map { RemoteItem(path: $0, kind: .directory) }
    }

    func make(_ path: RemotePath) {
        made.withLock { $0.append(path) }
    }
}

@MainActor @Suite struct FolderTreeTests {
    private let server = Folders()

    private func tree(chosen: RemotePath? = nil, canMake: Bool = true) -> FolderTree {
        let server = server
        // A closure inside `? :` isn't taken as sendable, so each case is written whole.
        guard canMake else {
            return FolderTree(chosen: chosen, list: { try server.list($0) })
        }
        return FolderTree(chosen: chosen, list: { try server.list($0) }, make: { server.make($0) })
    }

    @Test func onlyFoldersAreListedAndHiddenOnesArent() async {
        let tree = tree()
        await tree.load()
        // In the order a person reads them: 9 before 10, and capitals don't matter.
        #expect(tree.folders == ["Archive 9", "Archive 10", "documents", "Photos"])
    }

    @Test func aNameGoesInsideAndBackComesOut() async {
        let tree = tree()
        await tree.load()
        await tree.open("Photos")
        #expect(tree.folder == RemotePath("Photos"))
        #expect(tree.folders == ["2026"])
        await tree.back()
        #expect(tree.folder == .root)
        #expect(tree.folders.contains("Photos"))
    }

    /// Going inside a folder never chooses it, and choosing never goes inside.
    @Test func lookingAndChoosingAreSeparate() async {
        let tree = tree()
        await tree.load()
        await tree.open("Photos")
        #expect(tree.chosen == nil)
        tree.choose(RemotePath("Photos/2026")!)
        #expect(tree.folder == RemotePath("Photos"))
        #expect(tree.chosen == RemotePath("Photos/2026"))
    }

    @Test func aChosenFolderOpensWhereItShows() {
        let tree = tree(chosen: RemotePath("Photos/2026"))
        #expect(tree.folder == RemotePath("Photos"))
        #expect(tree.chosen == RemotePath("Photos/2026"))
    }

    @Test func aMadeFolderIsChosen() async {
        let tree = tree()
        await tree.load()
        #expect(await tree.create("  New  "))
        #expect(server.created == [RemotePath("New")!])
        #expect(tree.chosen == RemotePath("New"))
        #expect(tree.folders.contains("New"))
    }

    @Test(arguments: ["", "  ", ".cloudmount", "..", "a/b"])
    func aNameThatCantBeAFolderIsRefused(name: String) async {
        let tree = tree()
        await tree.load()
        #expect(!(await tree.create(name)))
        #expect(server.created.isEmpty)
        #expect(tree.problem == "That name can't be used for a folder.")
    }

    /// The iPhone writes nothing to a server, so its picker can't make a folder at all.
    @Test func aPickerThatCantWriteMakesNothing() async {
        let tree = tree(canMake: false)
        #expect(!tree.canCreate)
        #expect(!(await tree.create("New")))
        #expect(server.created.isEmpty)
    }

    @Test func aFolderThatCantBeReadSaysSo() async {
        let tree = FolderTree(list: { _ in throw RemoteError.unauthorized })
        await tree.load()
        #expect(tree.folders.isEmpty)
        #expect(tree.problem?.hasPrefix("This folder can't be read:") == true)
    }

    @Test func aChosenFolderBecomesTheFieldOnEachProtocol() throws {
        var webDAV = ConnectionForm()
        webDAV.host = "box.example.com"
        var sftp = webDAV
        sftp.kind = .sftp
        let chosen = try #require(RemotePath("Photos/2026"))
        #expect(webDAV.folderField(for: chosen) == "/Photos/2026")
        #expect(sftp.folderField(for: chosen) == "Photos/2026")
        sftp.path = "/"
        #expect(sftp.folderField(for: chosen) == "/Photos/2026")
    }

    @Test func theTypedFolderIsChosenWhenThePickerOpens() throws {
        var form = ConnectionForm()
        form.kind = .sftp
        form.host = "box.example.com"
        form.path = "~/Photos/2026"
        #expect(form.typedFolder(inside: form.atTopFolder) == RemotePath("Photos/2026"))
        // A folder from the server's top isn't inside the home folder, where looking starts.
        form.path = "/srv/photos"
        #expect(form.typedFolder(inside: form.atTopFolder) == nil)
    }
}
