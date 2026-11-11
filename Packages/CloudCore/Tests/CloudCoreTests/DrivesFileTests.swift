// Apache 2 license - developer@infinitecontext.com

@testable import CloudCore
import Foundation
import Testing

/// A drives file carries drives and their passwords to another device, sealed with one password.
@Suite struct DrivesFileTests {
    private let password = "correct horse battery staple"

    private func entry(
        _ name: String = "Work", folder: String = "/files/cloudmount-test", host: String = "files.example.com"
    ) -> DrivesFile.Entry {
        var connection = Connection(
            displayName: name, endpoint: .sftp(host: host, port: 22), username: "me", rootPath: folder,
            isEncrypted: true, hostKey: "ssh-ed25519 AAAAexample")
        connection.vaultID = "vault-1"
        connection.vaultRevision = 3
        connection.settings.mode = .unsafe
        return DrivesFile.Entry(connection, credentials: Credentials(
            password: "server-secret-1", privateKeyPEM: "-----BEGIN OPENSSH PRIVATE KEY-----\nkeybytes",
            privateKeyPassphrase: "key-secret-2", vaultPassword: "vault-secret-3"))
    }

    private func envelope(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func aFileOpensWithItsPasswordExactlyAsSealed() throws {
        let drives = [entry(), entry("Photos", folder: "/photos/cloudmount-test")]
        let data = try DrivesFile.seal(drives, password: password)
        #expect(try DrivesFile.open(data, password: password) == drives)
    }

    @Test func aWrongPasswordReadsNothing() throws {
        let data = try DrivesFile.seal([entry()], password: password)
        #expect(throws: DrivesFile.FileError.wrongPasswordOrChanged) {
            try DrivesFile.open(data, password: password + "!")
        }
    }

    @Test func aChangedBodyIsRefused() throws {
        var fields = try envelope(try DrivesFile.seal([entry()], password: password))
        let encoded = try #require(fields["sealed"] as? String)
        var sealed = try #require(Data(base64Encoded: encoded))
        sealed[sealed.count / 2] ^= 0x01
        fields["sealed"] = sealed.base64EncodedString()
        let changed = try JSONSerialization.data(withJSONObject: fields)
        #expect(throws: DrivesFile.FileError.wrongPasswordOrChanged) {
            try DrivesFile.open(changed, password: password)
        }
    }

    /// The header is authenticated too, so even a field the key doesn't come from can't be changed.
    @Test func aChangedHeaderIsRefused() throws {
        var fields = try envelope(try DrivesFile.seal([entry()], password: password))
        var header = try #require(fields["header"] as? [String: Any])
        header["format"] = 0
        fields["header"] = header
        let changed = try JSONSerialization.data(withJSONObject: fields)
        #expect(throws: DrivesFile.FileError.wrongPasswordOrChanged) {
            try DrivesFile.open(changed, password: password)
        }
    }

    @Test func aNewerFormatIsRefusedBeforeAnythingIsRead() throws {
        var fields = try envelope(try DrivesFile.seal([entry()], password: password))
        var header = try #require(fields["header"] as? [String: Any])
        header["format"] = DrivesFile.currentFormat + 1
        fields["header"] = header
        let newer = try JSONSerialization.data(withJSONObject: fields)
        #expect(throws: DrivesFile.FileError.newerFormat) {
            try DrivesFile.open(newer, password: password)
        }
    }

    @Test func anythingElseIsNotADrivesFile() {
        for data in [Data(), Data("{}".utf8), Data("hello".utf8), Data(#"{"header":{"kind":"x"}}"#.utf8)] {
            #expect(throws: DrivesFile.FileError.notADrivesFile) {
                try DrivesFile.open(data, password: password)
            }
        }
    }

    /// Nothing about the drives is readable without the password: no secret, no name, no server.
    @Test func theFileShowsNothingInTheClear() throws {
        let data = try DrivesFile.seal([entry()], password: password)
        let text = String(decoding: data, as: UTF8.self)
        for hidden in ["server-secret-1", "keybytes", "key-secret-2", "vault-secret-3", "Work", "files.example.com", password] {
            #expect(!text.contains(hidden), "\(hidden) is readable")
            #expect(data.range(of: Data(hidden.utf8)) == nil)
        }
    }

    @Test func aShortPasswordOrNoDrivesIsRefused() {
        #expect(throws: DrivesFile.FileError.passwordTooShort) {
            try DrivesFile.seal([entry()], password: "too short")
        }
        #expect(throws: DrivesFile.FileError.nothingToExport) {
            try DrivesFile.seal([], password: password)
        }
    }

    @Test func theOfferedPassphraseIsLongEnough() {
        #expect(Passphrase.generate().count >= DrivesFile.shortestPassword)
    }

    @Test func aFileIsNamedByItsDay() {
        let day = Date(timeIntervalSince1970: 1_794_268_800)
        #expect(DrivesFile.suggestedName(now: day) == "CloudAccess Drives 2026-11-10.cadrives")
    }
}

/// Importing: a person chooses each step for each drive, and nothing is ever removed.
@Suite struct DrivesFileImportTests {
    private func drive(_ name: String, folder: String, user: String = "me") -> Connection {
        Connection(displayName: name, endpoint: .sftp(host: "files.example.com", port: 22), username: user, rootPath: folder)
    }

    private func entry(_ connection: Connection, mode: DriveMode = .safe) -> DrivesFile.Entry {
        var connection = connection
        connection.settings.mode = mode
        return DrivesFile.Entry(connection, credentials: Credentials(password: "secret"))
    }

    private let here = [
        Connection(displayName: "Work", endpoint: .sftp(host: "files.example.com", port: 22), username: "me", rootPath: "/work/cloudmount-test"),
        Connection(displayName: "Photos", endpoint: .sftp(host: "files.example.com", port: 22), username: "me", rootPath: "/photos/cloudmount-test"),
        Connection(displayName: "Photos 2", endpoint: .sftp(host: "files.example.com", port: 22), username: "me", rootPath: "/old/cloudmount-test"),
    ]

    @Test func eachDriveIsSortedAgainstTheDrivesHere() {
        let rows = DrivesFileImport.rows(for: [
            entry(drive("New", folder: "/new/cloudmount-test")),
            entry(drive("Office", folder: "/work/cloudmount-test")),
            entry(drive("Photos", folder: "/elsewhere/cloudmount-test")),
        ], among: here, on: .mac)
        #expect(rows.map(\.situation) == [
            .new,
            .alreadyHere(here[0].id),
            .nameTaken(suggested: "Photos 3"),
        ])
    }

    /// A drive that isn't here yet starts on Add, under a free name if its own is taken. One
    /// already here starts on Skip, and is never offered Add.
    @Test func aDriveNotHereYetStartsOnAddAndOneHereOnSkip() {
        let rows = DrivesFileImport.rows(for: [
            entry(drive("New", folder: "/new/cloudmount-test")),
            entry(drive("Office", folder: "/work/cloudmount-test")),
            entry(drive("Photos", folder: "/elsewhere/cloudmount-test")),
        ], among: here, on: .mac)
        for row in rows {
            #expect(row.steps.first == .skip)
            #expect(row.steps.contains(row.startingStep))
        }
        #expect(rows.map(\.startingStep) == [.add, .skip, .addAs("Photos 3")])
        #expect(rows[0].steps == [.skip, .add])
        #expect(rows[1].steps == [.skip, .updatePasswords, .updatePasswordsAndSettings])
        #expect(rows[2].steps == [.skip, .addAs("Photos 3")])
    }

    /// A file can list one server folder twice, or two drives under one name. Left as they start,
    /// the folder is added once, and the second name gets a number.
    @Test func aFileNeverAddsOneFolderOrOneNameTwice() {
        let rows = DrivesFileImport.rows(for: [
            entry(drive("Trips", folder: "/trips/cloudmount-test")),
            entry(drive("Trips copy", folder: "/trips/cloudmount-test")),
            entry(drive("Trips", folder: "/more-trips/cloudmount-test")),
            entry(drive("Office", folder: "/work/cloudmount-test")),
            entry(drive("Office again", folder: "/work/cloudmount-test")),
        ], among: here, on: .mac)
        #expect(rows.map(\.situation) == [
            .new,
            .listedTwice,
            .nameTaken(suggested: "Trips 2"),
            .alreadyHere(here[0].id),
            .alreadyHere(here[0].id),
        ])
        #expect(rows.map(\.startingStep) == [.add, .skip, .addAs("Trips 2"), .skip, .skip])
        #expect(rows[1].steps == [.skip])
    }

    @Test func anAddedDriveHasAnIDOfItsOwn() throws {
        let row = try #require(DrivesFileImport.rows(
            for: [entry(drive("New", folder: "/new/cloudmount-test"))], among: here, on: .phone).first)
        let first = try #require(DrivesFileImport.newDrive(for: row, step: .add, allowsInsecure: false))
        let second = try #require(DrivesFileImport.newDrive(for: row, step: .add, allowsInsecure: false))
        #expect(first.id != second.id)
        #expect(!here.map(\.id).contains(first.id))
        #expect(DrivesFileImport.newDrive(for: row, step: .skip, allowsInsecure: false) == nil)
    }

    /// Consent to send a password over plain http belongs to each device, so a file never carries
    /// it, and an http drive is only added once this device gives its own.
    @Test func plainHTTPNeedsThisDevicesOwnConsent() throws {
        var insecure = Connection(
            displayName: "Old NAS", endpoint: .webDAV(url: URL(string: "http://nas.local/cloudmount-test")!))
        insecure.allowsInsecure = true
        let carried = DrivesFile.Entry(insecure, credentials: Credentials(password: "secret"))
        let json = String(decoding: try JSONEncoder().encode(carried), as: UTF8.self)
        #expect(!json.contains("Insecure"))

        let row = try #require(DrivesFileImport.rows(for: [carried], among: [], on: .mac).first)
        #expect(row.needsInsecureConsent)
        #expect(DrivesFileImport.newDrive(for: row, step: .add, allowsInsecure: false) == nil)
        #expect(DrivesFileImport.newDrive(for: row, step: .add, allowsInsecure: true)?.allowsInsecure == true)
    }

    @Test func anUpdateKeepsTheDrivesOwnIdentity() throws {
        var existing = here[0]
        existing.vaultID = "vault-here"
        let row = try #require(DrivesFileImport.rows(
            for: [entry(drive("Office", folder: "/work/cloudmount-test"), mode: .unsafe)], among: [existing], on: .mac).first)
        let passwordsOnly = try #require(DrivesFileImport.updatedDrive(existing, for: row, step: .updatePasswords))
        #expect(passwordsOnly == existing)
        let withSettings = try #require(DrivesFileImport.updatedDrive(existing, for: row, step: .updatePasswordsAndSettings))
        #expect(withSettings.id == existing.id)
        #expect(withSettings.displayName == "Work")
        #expect(withSettings.vaultID == "vault-here")
        #expect(withSettings.settings.mode == .unsafe)
    }

    @Test func aWebDAVDriveInUnsafeModeCantBeAddedToAMac() throws {
        let webDAV = Connection(
            displayName: "Web", endpoint: .webDAV(url: URL(string: "https://files.example.com/cloudmount-test")!))
        let row = try #require(DrivesFileImport.rows(for: [entry(webDAV, mode: .unsafe)], among: [], on: .mac).first)
        #expect(row.steps == [.skip])
    }

    #if DEBUG
    @Test func aTestBuildRefusesADriveOutsideTheTestFolder() throws {
        let row = try #require(DrivesFileImport.rows(
            for: [entry(drive("Real", folder: "/real-files"))], among: [], on: .mac).first)
        #expect(row.steps == [.skip])
        guard case .notPossible = row.situation else {
            Issue.record("not refused: \(row.situation)")
            return
        }
    }
    #endif

    /// A step that fails partway takes back what it did, newest first, and never runs the rest.
    @Test func aStepThatFailsPartwayChangesNothing() async {
        struct Refused: Error {}
        var log: [String] = []
        let actions = [
            DrivesFileImport.Action(run: { log.append("save secrets") }, undo: { log.append("forget secrets") }),
            DrivesFileImport.Action(run: { log.append("save record") }, undo: { log.append("forget record") }),
            DrivesFileImport.Action(run: { throw Refused() }, undo: { log.append("never done") }),
            DrivesFileImport.Action(run: { log.append("never reached") }),
        ]
        do {
            try await DrivesFileImport.allOrNothing(actions)
            Issue.record("the failing step was passed over")
        } catch is Refused {
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        #expect(log == ["save secrets", "save record", "forget record", "forget secrets"])
    }
}
