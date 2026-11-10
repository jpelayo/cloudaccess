// Apache 2 license - developer@infinitecontext.com

import CloudCore
import Foundation
import RemoteEngine
import Testing

/// Exercises the real Go engine through its C interface, over a local folder.
@Suite struct RemoteEngineTests {
    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("CloudAccessTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func connection(server: URL, encrypted: Bool = true) -> Connection {
        Connection(
            displayName: "Test", endpoint: .localFolder, rootPath: server.path, isEncrypted: encrypted)
    }

    private func engine(server: URL, encrypted: Bool = true) async throws -> RemoteEngine {
        try await RemoteEngine(
            connection: connection(server: server, encrypted: encrypted),
            credentials: Credentials(vaultPassword: "correct horse"),
            createVault: encrypted)
    }

    /// Through the real engine, because the other tests of this use a fake one.
    @Test func aNameAnEncryptedDriveCantHoldIsRefused() async throws {
        let server = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: server) }
        let engine = try await engine(server: server)

        try await engine.checkName(RemotePath("/short.txt")!)
        await #expect(throws: RemoteError.self) {
            try await engine.checkName(RemotePath("/" + String(repeating: "a", count: 200))!)
        }
    }

    /// Through the real engine, so both sides agree on the unit: a day read as seconds would purge.
    @Test func aDriveKeepsDeletedFilesForTheTimeChosen() async throws {
        let server = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: server) }
        let engine = try await engine(server: server)

        #expect(try await engine.trashRetentionSeconds() == TrashRetention.defaultSeconds)
        for choice in TrashRetention.choices {
            try await engine.setTrashRetention(seconds: choice.seconds)
            #expect(try await engine.trashRetentionSeconds() == choice.seconds)
        }
        await #expect(throws: (any Error).self) {
            try await engine.setTrashRetention(seconds: 1)
        }
    }

    /// The add form's path through a server that already has files at the top, as a Storage Box
    /// does: an encrypted drive is refused there, and looking around leaves no trace.
    @Test func aFolderMadeWhileBrowsingCanHoldAnEncryptedDrive() async throws {
        let server = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: server) }
        try Data("already here".utf8).write(to: server.appendingPathComponent("existing.txt"))
        try FileManager.default.createDirectory(
            at: server.appendingPathComponent("Photos"), withIntermediateDirectories: true)

        await #expect(throws: RemoteError.vault(.missing)) {
            _ = try await engine(server: server)
        }
        #expect(!FileManager.default.fileExists(atPath: server.appendingPathComponent(".cloudmount").path))

        let browser = try await RemoteEngine(
            connection: connection(server: server, encrypted: false), credentials: Credentials())
        let folders = try await browser.list(.root).filter { $0.kind == .directory }.map(\.path.name)
        #expect(folders == ["Photos"])
        let top = try FileManager.default.contentsOfDirectory(atPath: server.path).sorted()
        #expect(top == ["Photos", "existing.txt"])

        let chosen = try #require(RemotePath("/New Drive"))
        try await browser.createDirectory(chosen)
        let inside = server.appendingPathComponent("New Drive")
        #expect(FileManager.default.fileExists(atPath: inside.path))

        let drive = try await engine(server: inside)
        #expect(drive.vault != nil)
    }

    @Test func encryptedRoundTrip() async throws {
        let server = try temporaryFolder()
        let work = try temporaryFolder()
        defer {
            try? FileManager.default.removeItem(at: server)
            try? FileManager.default.removeItem(at: work)
        }
        let backend = try await engine(server: server)
        #expect(backend.vault != nil)

        let source = work.appendingPathComponent("source.txt")
        try Data("el secreto".utf8).write(to: source)
        let path = try #require(RemotePath("/Clientes/Contrato.txt"))

        let uploaded = try await backend.upload(from: source, to: path)
        #expect(uploaded.size == 10)

        let onServer = try FileManager.default.subpathsOfDirectory(atPath: server.path)
        #expect(!onServer.contains { $0.contains("Clientes") || $0.contains("Contrato") })

        let listing = try await backend.list(try #require(RemotePath("/Clientes")))
        #expect(listing.map(\.path) == [path])
        #expect(listing.first?.kind == .file)

        let destination = work.appendingPathComponent("out.txt")
        try await backend.download(path, to: destination)
        #expect(try Data(contentsOf: destination) == Data("el secreto".utf8))
    }

    @Test func wrongPasswordIsRefused() async throws {
        let server = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: server) }
        _ = try await engine(server: server)

        await #expect(throws: RemoteError.vault(.wrongPassword)) {
            _ = try await RemoteEngine(
                connection: connection(server: server),
                credentials: Credentials(vaultPassword: "mistyped"))
        }
    }

    @Test func aSecondDeviceFindsTheSameVault() async throws {
        let server = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: server) }
        let first = try await engine(server: server)
        let second = try await RemoteEngine(
            connection: connection(server: server),
            credentials: Credentials(vaultPassword: "correct horse"))
        #expect(first.vault == second.vault)
    }

    /// Requests can connect together when macOS starts the extension. Releasing the spare
    /// engine must not close the drive for the one still in use.
    @Test func releasingOneEngineLeavesAnotherForTheSameDriveWorking() async throws {
        let server = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: server) }
        let shared = connection(server: server)
        let credentials = Credentials(vaultPassword: "correct horse")
        var spare: RemoteEngine? = try await RemoteEngine(
            connection: shared, credentials: credentials, createVault: true)
        let kept = try await RemoteEngine(connection: shared, credentials: credentials)
        #expect(spare?.vault == kept.vault)

        spare = nil
        // Closing runs on the engine's queue, after the last reference goes.
        try await Task.sleep(for: .milliseconds(300))

        #expect(try await kept.list(.root).isEmpty)
    }

    @Test func aPinnedDriveRefusesAnotherVault() async throws {
        let server = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: server) }
        _ = try await engine(server: server)

        var pinned = connection(server: server)
        pinned.vaultID = "another-vault"
        await #expect(throws: RemoteError.vault(.mismatch)) {
            _ = try await RemoteEngine(
                connection: pinned, credentials: Credentials(vaultPassword: "correct horse"))
        }
    }

    @Test func missingItemIsAnItemError() async throws {
        let server = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: server) }
        let backend = try await engine(server: server)
        let path = try #require(RemotePath("/missing"))

        await #expect(throws: RemoteError.notFound(path)) {
            _ = try await backend.item(at: path)
        }
    }

    @Test func foldersMoveAndDelete() async throws {
        let server = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: server) }
        let backend = try await engine(server: server, encrypted: false)

        let first = try #require(RemotePath("/a/b"))
        let second = try #require(RemotePath("/c"))
        try await backend.createDirectory(first)
        try await backend.move(from: first, to: second)
        #expect(try await backend.item(at: second).kind == .directory)

        try await backend.delete(second)
        await #expect(throws: RemoteError.notFound(second)) {
            _ = try await backend.item(at: second)
        }
    }

    /// The task is already cancelled before the engine call starts, so this must fail:
    /// a cancel can't be lost, however early it arrives.
    @Test func aCancelledTaskNeverReachesTheServer() async throws {
        let server = try temporaryFolder()
        let work = try temporaryFolder()
        defer {
            try? FileManager.default.removeItem(at: server)
            try? FileManager.default.removeItem(at: work)
        }
        let backend = try await engine(server: server)
        let source = work.appendingPathComponent("large.bin")
        try Data(count: 16 * 1024 * 1024).write(to: source)
        let path = try #require(RemotePath("/large.bin"))

        let upload = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await backend.upload(from: source, to: path)
        }
        await #expect(throws: RemoteError.cancelled) {
            _ = try await upload.value
        }
        await #expect(throws: RemoteError.notFound(path)) {
            _ = try await backend.item(at: path)
        }
    }
}
