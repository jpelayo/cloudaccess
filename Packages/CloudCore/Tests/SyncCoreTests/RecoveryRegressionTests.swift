// Apache 2 license - developer@infinitecontext.com

import CloudCore
import Foundation
import SQLite3
import Testing

@testable import SyncCore

// These came from the second assessment. Each failed before its fix.

@Suite struct RecoveryRegressionTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func entry(_ name: String) -> RemoteItem {
        RemoteItem(path: RemotePath("/\(name)")!, kind: .file, size: 1, versionID: "v1")
    }

    private func store() throws -> SyncStore {
        try SyncStore(url: try folder().appendingPathComponent("a.sqlite"))
    }

    // MARK: In-flight marks (R09)

    @Test(arguments: [true, false])
    func overlappingOperationsStayProtectedInEitherOrder(firstFinishesFirst: Bool) throws {
        let store = try store()
        let item = try store.recordCreated(entry("a.txt"), in: SyncItem.rootID)
        let first = try store.beginOperation(item: item.id, kind: "first")
        let second = try store.beginOperation(item: item.id, kind: "second")
        try store.finishOperation(id: firstFinishesFirst ? first : second)
        let generation = try store.item(id: SyncItem.rootID)?.generation ?? 0

        #expect(try store.removeConfirmed(item, parentGeneration: generation) == false)

        try store.finishOperation(id: firstFinishesFirst ? second : first)
        #expect(try store.removeConfirmed(item, parentGeneration: generation) == true)
    }

    @Test func aDeadProcessesMarkExpiresByAge() throws {
        let store = try store()
        let item = try store.recordCreated(entry("a.txt"), in: SyncItem.rootID)
        let now = Date()
        _ = try store.beginOperation(item: item.id, kind: "old", now: now.addingTimeInterval(-2 * 86_400))
        let generation = try store.item(id: SyncItem.rootID)?.generation ?? 0

        #expect(try store.removeConfirmed(item, parentGeneration: generation, now: now) == true)
    }

    // MARK: Upgrades (R10)

    private func legacyDatabase(at url: URL) {
        var handle: OpaquePointer?
        #expect(sqlite3_open(url.path, &handle) == SQLITE_OK)
        let legacy = """
            CREATE TABLE items(
                id TEXT PRIMARY KEY, parent TEXT, name TEXT NOT NULL, kind INTEGER NOT NULL,
                size INTEGER, modified REAL, version TEXT NOT NULL DEFAULT '', etag TEXT,
                generation INTEGER NOT NULL DEFAULT 0, last_listed REAL, last_opened REAL,
                missing_passes INTEGER NOT NULL DEFAULT 0, missing_since REAL,
                UNIQUE(parent, name));
            INSERT INTO items(id, parent, name, kind) VALUES ('root', NULL, '', 1);
            INSERT INTO items(id, parent, name, kind, version) VALUES ('kept', 'root', 'kept.txt', 0, 'old');
            """
        #expect(sqlite3_exec(handle, legacy, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(handle)
    }

    @Test func anOlderDatabaseGetsTheColumnsItNeedsAndKeepsItsItems() throws {
        let url = try folder().appendingPathComponent("a.sqlite")
        legacyDatabase(at: url)

        let store = try SyncStore(url: url)

        #expect(throws: Never.self) {
            _ = try store.recordCreated(entry("a.txt"), in: SyncItem.rootID)
        }
        #expect(try store.item(id: "kept")?.name == "kept.txt")
    }

    @Test func anOlderDatabaseIsBackedUpBeforeUpgrading() throws {
        let url = try folder().appendingPathComponent("a.sqlite")
        legacyDatabase(at: url)

        _ = try SyncStore(url: url)

        let backup = url.deletingPathExtension().appendingPathExtension("before-upgrade")
        #expect(FileManager.default.fileExists(atPath: backup.path))
    }

    @Test func aNewDatabaseNeedsNoBackup() throws {
        let url = try folder().appendingPathComponent("a.sqlite")

        _ = try SyncStore(url: url)

        let backup = url.deletingPathExtension().appendingPathExtension("before-upgrade")
        #expect(!FileManager.default.fileExists(atPath: backup.path))
    }

    // MARK: Repair (R11)

    @Test func aFailedBackupKeepsTheLastGoodOne() throws {
        let base = try folder()
        let store = try SyncStore(url: base.appendingPathComponent("a.sqlite"))
        let backup = base.appendingPathComponent("a.backup")
        try store.backUp(to: backup)
        let before = try Data(contentsOf: backup)

        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: base.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: base.path) }
        #expect(throws: (any Error).self) { try store.backUp(to: backup) }

        #expect(try Data(contentsOf: backup) == before)
    }

    @Test func aBackupLeavesNothingElseBehind() throws {
        let base = try folder()
        let store = try SyncStore(url: base.appendingPathComponent("a.sqlite"))
        let backup = base.appendingPathComponent("a.backup")
        try store.backUp(to: backup)
        try store.backUp(to: backup)

        #expect(FileManager.default.fileExists(atPath: backup.path))
        #expect(!FileManager.default.fileExists(atPath: backup.path + ".partial"))
    }

    @Test func aLostDatabaseWithNoBackupIsARecovery() throws {
        let base = try folder()
        let url = base.appendingPathComponent("a.sqlite")
        let backup = base.appendingPathComponent("a.backup")
        do { _ = try SyncStore.opening(url: url, backup: backup) }
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }

        let opened = try SyncStore.opening(url: url, backup: backup)

        #expect(opened.recovery == .startedAgain)
        #expect(try opened.store.needsRebuild())
    }

    @Test func aNewDriveIsNotARecovery() throws {
        let base = try folder()
        let opened = try SyncStore.opening(
            url: base.appendingPathComponent("a.sqlite"), backup: base.appendingPathComponent("a.backup"))

        #expect(opened.recovery == .none)
        #expect(try opened.store.needsRebuild() == false)
    }

    @Test func aDamagedDatabaseIsSetAsideWithItsSidecars() throws {
        let base = try folder()
        let url = base.appendingPathComponent("a.sqlite")
        let backup = base.appendingPathComponent("a.backup")
        try Data(repeating: 0xAB, count: 16_384).write(to: url)
        try Data("log".utf8).write(to: URL(fileURLWithPath: url.path + "-wal"))

        let opened = try SyncStore.opening(url: url, backup: backup)

        #expect(opened.recovery == .startedAgain)
        #expect(FileManager.default.fileExists(atPath: url.path + ".damaged"))
        #expect(FileManager.default.fileExists(atPath: url.path + ".damaged-wal"))
        #expect(try opened.store.needsRebuild())
    }

    @Test func aRepairNoticesAStoreThatsBeenReplaced() throws {
        let base = try folder()
        let url = base.appendingPathComponent("a.sqlite")
        let backup = base.appendingPathComponent("a.backup")
        let first = try SyncStore.opening(url: url, backup: backup).store
        #expect(first.isCurrent)

        // Another process repairs the database while this one still has it open.
        try FileManager.default.moveItem(at: url, to: base.appendingPathComponent("elsewhere.sqlite"))
        let second = try SyncStore.opening(url: url, backup: backup).store

        #expect(!first.isCurrent)
        #expect(second.isCurrent)
    }

    @Test func aRebuildFlagIsClearedByTheApp() throws {
        let store = try store()
        try store.setNeedsRebuild(true)
        #expect(try store.needsRebuild())
        try store.setNeedsRebuild(false)
        #expect(try store.needsRebuild() == false)
    }

    // MARK: Pages (R18)

    @Test func aListingThatAddsAnItemExpiresPagesInProgress() throws {
        let store = try store()
        _ = try store.recordCreated(entry("a.txt"), in: SyncItem.rootID)
        let before = try store.item(id: SyncItem.rootID)?.generation

        try store.apply(listing: [entry("a.txt"), entry("b.txt")], in: SyncItem.rootID, generation: before)

        #expect(try store.item(id: SyncItem.rootID)?.generation != before)
    }

    @Test func aListingWithNothingNewLeavesPagesAlone() throws {
        let store = try store()
        _ = try store.recordCreated(entry("a.txt"), in: SyncItem.rootID)
        let before = try store.item(id: SyncItem.rootID)?.generation

        try store.apply(listing: [entry("a.txt")], in: SyncItem.rootID, generation: before)

        #expect(try store.item(id: SyncItem.rootID)?.generation == before)
    }
}
