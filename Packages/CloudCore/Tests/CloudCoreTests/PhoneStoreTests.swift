// Apache 2 license - developer@infinitecontext.com

import CloudCore
import Foundation
import Testing

/// The iPhone app's drives move into the folder its Files extension can read. A move that goes
/// wrong must never leave the app with fewer drives than it had.
@Suite struct PhoneStoreTests {
    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhoneStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func drive(_ name: String) -> Connection {
        Connection(displayName: name, endpoint: .webDAV(url: URL(string: "https://example.invalid/\(name)")!))
    }

    @Test func withoutTheSharedFolderTheAppKeepsItsOwn() throws {
        let own = try temporaryFolder()
        try DriveStore(directory: own).save(drive("Work"))
        let (store, isShared) = DriveStore.phone(ownFolder: own, shared: nil)
        #expect(!isShared)
        #expect(try store.connections().map(\.displayName) == ["Work"])
    }

    @Test func theDrivesMoveWhereTheExtensionReadsThem() throws {
        let own = try temporaryFolder()
        let sharedFolder = try temporaryFolder()
        try DriveStore(directory: own).save(drive("Work"))
        try DriveStore(directory: own).save(drive("Photos"))
        let (store, isShared) = DriveStore.phone(ownFolder: own, shared: DriveStore(directory: sharedFolder))
        #expect(isShared)
        #expect(try store.connections().map(\.displayName) == ["Work", "Photos"])
        #expect(try DriveStore(directory: sharedFolder).connections().count == 2)
        #expect(!FileManager.default.fileExists(atPath: own.appendingPathComponent("connections.json").path))
    }

    /// A shared folder that can't be written to leaves the drives where they were, and the app
    /// keeps using them there.
    @Test func aMoveThatFailsKeepsTheDrives() throws {
        let own = try temporaryFolder()
        try DriveStore(directory: own).save(drive("Work"))
        // A file where the folder should be makes every write there fail.
        let blocked = try temporaryFolder().appendingPathComponent("not-a-folder")
        try Data("x".utf8).write(to: blocked)
        let (store, isShared) = DriveStore.phone(ownFolder: own, shared: DriveStore(directory: blocked))
        #expect(!isShared)
        #expect(try store.connections().map(\.displayName) == ["Work"])
        #expect(FileManager.default.fileExists(atPath: own.appendingPathComponent("connections.json").path))
    }

    /// A move cut short after the copy leaves both lists. The next launch finishes it without
    /// doubling a drive or losing one added since.
    @Test func anUnfinishedMoveFinishesWithoutDoublingADrive() throws {
        let own = try temporaryFolder()
        let sharedFolder = try temporaryFolder()
        var work = drive("Work")
        try DriveStore(directory: own).save(work)
        try DriveStore(directory: own).save(drive("Photos"))
        work.displayName = "Work, renamed"
        try DriveStore(directory: sharedFolder).save(work)
        let (store, isShared) = DriveStore.phone(ownFolder: own, shared: DriveStore(directory: sharedFolder))
        #expect(isShared)
        #expect(try store.connections().map(\.displayName) == ["Work, renamed", "Photos"])
    }

    /// The Files extension deletes the databases of drives that are gone. A list that was never
    /// saved says nothing about any drive, so it must not read as an empty one.
    @Test func aMissingListIsntAnEmptyOne() throws {
        let folder = try temporaryFolder()
        #expect(try DriveStore(directory: folder).savedConnections() == nil)
        try Data("[]".utf8).write(to: folder.appendingPathComponent("connections.json"))
        #expect(try DriveStore(directory: folder).savedConnections() == [])
    }

    @Test func aLaterLaunchFindsNothingToMove() throws {
        let own = try temporaryFolder()
        let sharedFolder = try temporaryFolder()
        try DriveStore(directory: own).save(drive("Work"))
        _ = DriveStore.phone(ownFolder: own, shared: DriveStore(directory: sharedFolder))
        let (store, isShared) = DriveStore.phone(ownFolder: own, shared: DriveStore(directory: sharedFolder))
        #expect(isShared)
        #expect(try store.connections().map(\.displayName) == ["Work"])
    }
}
