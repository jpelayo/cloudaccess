// Apache 2 license - developer@infinitecontext.com

import CloudCore
import Foundation
import MountKit
import Testing

@Suite struct LocalContentsTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalContentsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func aPlainFileIsAFile() throws {
        let file = try folder().appendingPathComponent("doc.txt")
        try Data("hello".utf8).write(to: file)
        guard case .file(let size, _) = LocalContents.inspect(file) else {
            Issue.record("Not seen as a file")
            return
        }
        #expect(size == 5)
    }

    @Test func aFolderIsNotAFile() throws {
        let plain = try folder().appendingPathComponent("just a folder")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        #expect(LocalContents.inspect(plain) == .not(.folder))
    }

    /// The name can't be trusted either way: this is what makes a folder a package.
    @Test func aPackageIsTold() throws {
        let package = try folder().appendingPathComponent("Tool.app")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        #expect(LocalContents.inspect(package) == .not(.package))
    }

    @Test func aFileNamedLikeAPackageIsStillAFile() throws {
        let file = try folder().appendingPathComponent("flat.numbers")
        try Data("zip".utf8).write(to: file)
        guard case .file = LocalContents.inspect(file) else {
            Issue.record("A flat document is a file, whatever it's called")
            return
        }
    }

    /// Following a link would send whatever it points at.
    @Test func aLinkIsNotFollowed() throws {
        let place = try folder()
        let target = place.appendingPathComponent("target.txt")
        try Data("hello".utf8).write(to: target)
        let link = place.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(LocalContents.inspect(link) == .not(.link))
    }

    @Test func aMissingFileIsUnreadable() throws {
        let gone = try folder().appendingPathComponent("gone.txt")
        guard case .unreadable = LocalContents.inspect(gone) else {
            Issue.record("A missing file can't pass")
            return
        }
    }

    @Test func aFileThatCantBeOpenedIsUnreadable() throws {
        let file = try folder().appendingPathComponent("private.txt")
        try Data("hello".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        guard case .unreadable = LocalContents.inspect(file) else {
            Issue.record("A file that can't be read can't pass")
            return
        }
    }

    @Test func aChangeShows() throws {
        let file = try folder().appendingPathComponent("doc.txt")
        try Data("hello".utf8).write(to: file)
        let before = LocalContents.inspect(file)
        try Data("hello there".utf8).write(to: file)
        #expect(LocalContents.inspect(file) != before)
    }
}
