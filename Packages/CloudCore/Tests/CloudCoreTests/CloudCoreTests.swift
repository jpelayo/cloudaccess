// Apache 2 license - developer@infinitecontext.com

import Foundation
import Testing
@testable import CloudCore

@Suite struct RemotePathTests {
    @Test func normalisesSlashes() throws {
        let path = try #require(RemotePath("//a/b//c/"))
        #expect(path.description == "/a/b/c")
        #expect(path.name == "c")
        #expect(path.parent?.description == "/a/b")
    }

    @Test func rootHasNoParent() throws {
        let root = try #require(RemotePath("/"))
        #expect(root == .root)
        #expect(root.parent == nil)
        #expect(root.description == "/")
    }

    @Test func rejectsTraversal() {
        #expect(RemotePath("/a/../b") == nil)
        #expect(RemotePath("/a/./b") == nil)
        #expect(RemotePath.root.appending("..") == nil)
        #expect(RemotePath.root.appending("a/b") == nil)
    }

    @Test func survivesCoding() throws {
        let path = try #require(RemotePath("/Fotos/año 2026"))
        let decoded = try JSONDecoder().decode(RemotePath.self, from: JSONEncoder().encode(path))
        #expect(decoded == path)
    }
}

@Suite struct RemoteErrorTests {
    @Test func aMissingItemIsNeverAConnectionProblem() {
        #expect(RemoteError.notFound(.root).scope == .item)
        #expect(RemoteError.parentMissing(.root).scope == .item)
        #expect(RemoteError.failed(.root, "unknown").scope == .item)
    }

    @Test func signInFailureIsAConnectionProblem() {
        #expect(RemoteError.unauthorized.scope == .connection)
        #expect(RemoteError.unreachable("offline").scope == .connection)
    }

    @Test func onlyTransientFailuresRetry() {
        #expect(RemoteError.unreachable("offline").isRetryable)
        #expect(RemoteError.server(status: 503).isRetryable)
        #expect(!RemoteError.server(status: 400).isRetryable)
        #expect(!RemoteError.notFound(.root).isRetryable)
    }
}

@Suite struct ConnectionTests {
    private func connection() -> Connection {
        Connection(displayName: "Box", endpoint: .webDAV(url: URL(string: "https://example.com")!))
    }

    @Test func renamingKeepsTheDrive() {
        let original = connection()
        var renamed = original
        renamed.displayName = "Renamed"
        #expect(!renamed.requiresNewDrive(comparedTo: original))
    }

    @Test func changingTheFolderNeedsANewDrive() {
        let original = connection()
        var moved = original
        moved.rootPath = "/elsewhere"
        #expect(moved.requiresNewDrive(comparedTo: original))
    }
}

@Suite struct ServerAddressTests {
    @Test func httpsIsWebDAV() throws {
        let address = try #require(ServerAddress("https://example.com/cloudmount-test"))
        #expect(address.endpoint == .webDAV(url: URL(string: "https://example.com/cloudmount-test")!))
        #expect(address.rootPath == "")
    }

    @Test func sftpKeepsItsHostPortAndFolder() throws {
        let address = try #require(ServerAddress("sftp://example.com:2222/data/cloudmount-test"))
        #expect(address.endpoint == .sftp(host: "example.com", port: 2222))
        #expect(address.rootPath == "/data/cloudmount-test")
    }

    @Test func sftpDefaultsToPort22() throws {
        let address = try #require(ServerAddress("sftp://example.com/cloudmount-test"))
        #expect(address.endpoint == .sftp(host: "example.com", port: 22))
    }

    @Test func aTildeMeansTheHomeFolder() throws {
        let address = try #require(ServerAddress("sftp://example.com/~/docs/cloudmount-test"))
        #expect(address.rootPath == "docs/cloudmount-test")
    }

    @Test func surroundingSpaceFromPastingIsIgnored() {
        #expect(ServerAddress("  sftp://example.com/x\n") != nil)
    }

    @Test(arguments: ["HTTP://example.com/x", "HtTp://example.com/x", "http://example.com/x"])
    func anyCaseOfHTTPIsInsecure(address: String) throws {
        let server = try #require(ServerAddress(address))
        #expect(server.isInsecure)
        #expect(server.endpoint.isInsecure)
    }

    @Test func aScannedUppercaseHTTPStillNeedsConsent() throws {
        let url = try #require(URL(string: "HTTP://example.com/cloudmount-test"))
        let setup = ConnectionSetup(connection: Connection(displayName: "Work", endpoint: .webDAV(url: url)))

        let scanned = try ConnectionSetup(scanned: try setup.encoded())

        #expect(scanned.endpoint.isInsecure)
        #expect(!scanned.connection().allowsInsecure)
    }

    @Test func consentIsStoredOnTheDrive() throws {
        var connection = Connection(displayName: "Work", endpoint: .sftp(host: "example.com", port: 22))
        #expect(!connection.allowsInsecure)
        connection.allowsInsecure = true
        let decoded = try JSONDecoder().decode(Connection.self, from: JSONEncoder().encode(connection))
        #expect(decoded.allowsInsecure)
    }

    @Test func plainHTTPIsMarkedInsecure() throws {
        #expect(try #require(ServerAddress("http://example.com/x")).isInsecure)
        #expect(try !#require(ServerAddress("https://example.com/x")).isInsecure)
    }

    @Test(arguments: [
        "ftp://example.com/x", "example.com/x", "", "sftp://", "https://",
        "https://user:secret@example.com/x", "sftp://user@example.com/x",
        "https://example.com/x?a=b", "https://example.com/x#part",
    ])
    func refusesAnythingElse(text: String) {
        #expect(ServerAddress(text) == nil)
    }
}

@Suite struct PassphraseTests {
    @Test func theyAreLongAndDifferent() {
        let first = Passphrase.generate()
        #expect(first.count == 35)
        #expect(first != Passphrase.generate())
    }

    @Test func theyAvoidCharactersThatLookAlike() {
        for _ in 0..<50 {
            #expect(!Passphrase.generate().contains { "01ilo".contains($0) })
        }
    }
}

@Suite struct RecoveryKitTests {
    @Test func itHoldsWhatPlainRcloneNeeds() {
        let kit = RecoveryKit(
            driveName: "Work", address: "https://example.com", password: "pw", salt: "salty", vaultID: "v1")
        for part in ["pw", "salty", "v1", "filename_encoding = base32", "type = crypt"] {
            #expect(kit.text.contains(part))
        }
    }
}

@Suite struct DiagnosticsTests {
    @Test(arguments: [
        ("https://me:hunter2@example.com/x", "hunter2"),
        ("password=hunter2 failed", "hunter2"),
        (#"{"vaultPassword":"hunter2"}"#, "hunter2"),
        ("pass: hunter2", "hunter2"),
    ])
    func secretsAreRemoved(text: String, secret: String) {
        #expect(!Diagnostics.redact(text).contains(secret))
    }

    @Test func aPrivateKeyIsRemovedWhole() {
        let key = "-----BEGIN OPENSSH PRIVATE KEY-----\nabc\n-----END OPENSSH PRIVATE KEY-----"
        #expect(!Diagnostics.redact("before \(key) after").contains("abc"))
    }

    @Test func ordinaryTextIsLeftAlone() {
        #expect(Diagnostics.redact("poll failed: unreachable") == "poll failed: unreachable")
    }

    @Test func theLogKeepsWhatWasRecorded() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("diagnostics-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = Diagnostics(directory: folder)

        log.record("first")
        log.record("second password=hunter2")

        let text = log.exportedText(header: "header")
        #expect(text.contains("first"))
        #expect(text.contains("second"))
        #expect(!text.contains("hunter2"))
    }
}

@Suite struct ConnectionSetupTests {
    private func drive(encrypted: Bool = true) -> Connection {
        var connection = Connection(
            displayName: "Work", endpoint: .sftp(host: "example.com", port: 23), username: "me",
            rootPath: "/data", isEncrypted: encrypted, hostKey: "ssh-ed25519 AAAA")
        connection.vaultID = "vault"
        connection.vaultRevision = 2
        return connection
    }

    @Test func aCodeCarriesTheWholeSetup() throws {
        let text = try ConnectionSetup(connection: drive()).encoded()
        let scanned = try ConnectionSetup(scanned: text).connection()
        #expect(scanned.displayName == "Work")
        #expect(scanned.endpoint == .sftp(host: "example.com", port: 23))
        #expect(scanned.rootPath == "/data")
        #expect(scanned.hostKey == "ssh-ed25519 AAAA")
        #expect(scanned.vaultID == "vault")
        #expect(scanned.vaultRevision == 2)
    }

    @Test func aScannedDriveGetsItsOwnIdentity() throws {
        let original = drive()
        let text = try ConnectionSetup(connection: original).encoded()
        #expect(try ConnectionSetup(scanned: text).connection().id != original.id)
    }

    /// The whole point: `Connection` holds no secrets, and nothing adds one on the way.
    @Test func aCodeHoldsNoSecrets() throws {
        let text = try ConnectionSetup(connection: drive(), signsInWithKey: true).encoded()
        let payload = String(text.dropFirst("cloudaccess-setup:".count))
        let json = String(decoding: Data(base64Encoded: payload) ?? Data(), as: UTF8.self).lowercased()
        for word in ["password", "passphrase", "privatekey", "secret"] {
            #expect(!json.contains(word))
        }
    }

    @Test func aDriveThatSignsInWithAKeyAsksForTheKey() throws {
        let setup = ConnectionSetup(connection: drive(), signsInWithKey: true)
        #expect(setup.neededSecrets == [.privateKey, .encryptionPassword])
    }

    @Test func anEncryptedDriveAsksForBothPasswords() throws {
        #expect(ConnectionSetup(connection: drive()).neededSecrets == [.serverPassword, .encryptionPassword])
        #expect(ConnectionSetup(connection: drive(encrypted: false)).neededSecrets == [.serverPassword])
    }

    @Test(arguments: ["", "hello", "https://example.com", "cloudaccess-setup:", "cloudaccess-setup:!!!"])
    func otherCodesAreRefused(text: String) {
        #expect(throws: ConnectionSetup.SetupError.notASetupCode) {
            _ = try ConnectionSetup(scanned: text)
        }
    }

    @Test func aNewerFormatAsksForAnUpdate() throws {
        let newer = Data(#"{"format":99}"#.utf8).base64EncodedString()
        #expect(throws: ConnectionSetup.SetupError.newerFormat) {
            _ = try ConnectionSetup(scanned: "cloudaccess-setup:" + newer)
        }
    }

    @Test func aBadAddressInACodeIsRefused() throws {
        var setup = ConnectionSetup(connection: drive())
        setup.endpoint = .webDAV(url: URL(string: "ftp://example.com/x")!)
        #expect(throws: ConnectionSetup.SetupError.notASetupCode) {
            _ = try ConnectionSetup(scanned: try setup.encoded())
        }
    }
}

@Suite struct DriveRepairTests {
    private let one = UUID()

    @Test func aHealthyDriveNeedsNothing() {
        #expect(DriveRepair.plan(drives: [(one, .active)], domains: [one.uuidString]).isEmpty)
    }

    @Test func aSavedDriveWithNoDomainIsRegistered() {
        #expect(DriveRepair.plan(drives: [(one, .active)], domains: []) == [.register(one)])
    }

    @Test func anAddThatReachedTheDomainIsFinished() {
        #expect(DriveRepair.plan(drives: [(one, .adding)], domains: [one.uuidString]) == [.activate(one)])
    }

    @Test func anAddThatDidntIsRolledBack() {
        #expect(DriveRepair.plan(drives: [(one, .adding)], domains: []) == [.forget(one)])
    }

    @Test func aRemovalResumesEitherWay() {
        #expect(DriveRepair.plan(drives: [(one, .removing)], domains: []) == [.finishRemoving(one)])
        #expect(DriveRepair.plan(drives: [(one, .removing)], domains: [one.uuidString]) == [.finishRemoving(one)])
    }

    @Test func anUnknownDomainIsReportedAndNeverRemoved() {
        #expect(DriveRepair.plan(drives: [], domains: ["stranger"]) == [.reportUnknownDomain("stranger")])
    }
}

@Suite struct DriveSettingsTests {
    @Test func aSettingAddedLaterDoesntBreakOldRecords() throws {
        let old = Data(#"{"sizeLimit":5}"#.utf8)
        let settings = try JSONDecoder().decode(DriveSettings.self, from: old)
        #expect(settings.sizeLimit == 5)
        #expect(!settings.isReadOnly)
    }
}

@Suite struct LaunchRoleTests {
    @Test func aLoneCopyRunsWhenTheAgentIsOff() {
        let role = LaunchRole.decide(launchedByAgent: false, agentEnabled: false, otherCopy: nil)
        #expect(role == .run)
    }

    @Test func theAgentsCopyRuns() {
        let role = LaunchRole.decide(launchedByAgent: true, agentEnabled: true, otherCopy: nil)
        #expect(role == .run)
    }

    @Test func aHandOpenedCopyHandsOverToTheAgent() {
        let role = LaunchRole.decide(launchedByAgent: false, agentEnabled: true, otherCopy: nil)
        #expect(role == .handOver)
    }

    @Test func aHandOpenedCopyNeverDoubles() {
        let role = LaunchRole.decide(launchedByAgent: false, agentEnabled: true, otherCopy: 42)
        #expect(role == .leave(pid: 42))
    }

    @Test func theAgentsCopyWaitsForAPlainCopy() {
        let role = LaunchRole.decide(launchedByAgent: true, agentEnabled: true, otherCopy: 42)
        #expect(role == .standBy(pid: 42))
    }

    @Test func quitKeepsACopyStandingByFromRunning() {
        #expect(!ExitNote.shouldRun(afterExitOf: 42, note: ExitNote(pid: 42, reason: .quit)))
    }

    @Test func aCrashLeavesNoNoteAndItRuns() {
        #expect(ExitNote.shouldRun(afterExitOf: 42, note: nil))
    }

    @Test func anOldQuitDoesntStopALaterCopy() {
        #expect(ExitNote.shouldRun(afterExitOf: 42, note: ExitNote(pid: 7, reason: .quit)))
    }

    @Test func aNoteFromAnOlderBuildStillReads() throws {
        let older = Data(#"{"pid":42,"reason":"quit"}"#.utf8)
        let note = try JSONDecoder().decode(ExitNote.self, from: older)
        #expect(!ExitNote.shouldRun(afterExitOf: 42, note: note))
    }
}

@Suite struct ErrorMessageTests {
    @Test func aChangedServerIdentityIsAConnectionProblemWithAMessage() {
        #expect(RemoteError.hostKeyChanged.scope == .connection)
        #expect(RemoteError.hostKeyChanged.localizedDescription.contains("identity"))
    }

    @Test func aWrongEncryptionPasswordSaysSo() {
        #expect(RemoteError.vault(.wrongPassword).localizedDescription.contains("encryption password"))
    }
}

@Suite struct OfflineLibraryTests {
    private let drive = UUID()

    private func library() -> OfflineLibrary {
        OfflineLibrary(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    }

    private func path(_ text: String) -> RemotePath {
        RemotePath(text)!
    }

    @Test func aListingComesBackAfterSaving() throws {
        let library = library()
        let items = [RemoteItem(path: path("/Clients/a.txt"), kind: .file, size: 3, versionID: "v1")]

        try library.save(listing: items, of: path("/Clients"), drive: drive)

        #expect(library.listing(of: path("/Clients"), drive: drive) == items)
        #expect(library.hasListing(of: path("/Clients"), drive: drive))
    }

    @Test func aFolderNeverOpenedHasNoListing() {
        let library = library()
        #expect(library.listing(of: path("/Clients"), drive: drive) == nil)
        #expect(library.hasListing(of: .root, drive: drive) == false)
    }

    @Test func listingsDontLeakBetweenDrives() throws {
        let library = library()
        try library.save(listing: [], of: .root, drive: drive)
        #expect(library.hasListing(of: .root, drive: UUID()) == false)
    }

    private func finishedDownload(_ library: OfflineLibrary, text: String) throws -> URL {
        let file = try library.temporaryFile(drive: drive)
        try Data(text.utf8).write(to: file)
        return file
    }

    @Test func aDownloadOnlyCountsOnceKept() throws {
        let library = library()
        let target = path("/Clients/report.pdf")
        let file = try finishedDownload(library, text: "bytes")
        #expect(library.download(of: target, drive: drive) == nil)

        let kept = try library.keep(file, as: target, drive: drive)

        #expect(kept.lastPathComponent == "report.pdf")
        #expect(library.download(of: target, drive: drive) == kept)
        #expect(try String(contentsOf: kept, encoding: .utf8) == "bytes")
    }

    @Test func aNewerDownloadReplacesTheOldOne() throws {
        let library = library()
        let target = path("/report.pdf")
        try library.keep(try finishedDownload(library, text: "old"), as: target, drive: drive)

        let kept = try library.keep(try finishedDownload(library, text: "new"), as: target, drive: drive)

        #expect(try String(contentsOf: kept, encoding: .utf8) == "new")
    }

    @Test func aDownloadCanBeRemoved() throws {
        let library = library()
        let target = path("/report.pdf")
        try library.keep(try finishedDownload(library, text: "bytes"), as: target, drive: drive)

        library.removeDownload(of: target, drive: drive)

        #expect(library.download(of: target, drive: drive) == nil)
    }

    @Test func removingADriveForgetsEverything() throws {
        let library = library()
        let target = path("/report.pdf")
        try library.keep(try finishedDownload(library, text: "bytes"), as: target, drive: drive)
        try library.save(listing: [], of: .root, drive: drive)

        library.remove(drive: drive)

        #expect(library.download(of: target, drive: drive) == nil)
        #expect(library.hasListing(of: .root, drive: drive) == false)
    }
}
