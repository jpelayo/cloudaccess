// Apache 2 license - developer@infinitecontext.com

import Foundation
import Testing
@testable import CloudCore

/// A folder can be typed many ways. Each way must reach the folder a person meant, be shown so
/// it can be told apart from its look-alike, and never pass for a second drive.
@Suite struct ServerFolderTests {
    @Test(arguments: [
        ("Documents", "Documents"),
        ("~/Documents", "Documents"),
        ("/~/Documents", "Documents"),
        ("  Documents/  ", "Documents"),
        ("Documents//Photos/", "Documents/Photos"),
        ("", ""),
        ("~", ""),
        ("~/", ""),
        ("/~", ""),
        ("/Documents", "/Documents"),
        ("//Documents/", "/Documents"),
        ("/", "/"),
        ("my files/2026", "my files/2026"),
        ("~name/x", "~name/x"),
    ])
    func eachSFTPSpellingIsStoredOneWay(typed: String, stored: String) {
        #expect(ServerFolder.sftp(typed) == stored)
    }

    @Test(arguments: [
        ("Documents", "/Documents"),
        ("/Documents", "/Documents"),
        ("~/Documents", "/Documents"),
        ("//Documents//Photos/", "/Documents/Photos"),
        ("", ""),
        ("/", ""),
        ("~", ""),
    ])
    func eachWebDAVSpellingIsStoredOneWay(typed: String, stored: String) {
        #expect(ServerFolder.webDAV(typed) == stored)
    }

    @Test(arguments: ["..", "a/../b", "./a", "a/.", "~/..", "/a/.."])
    func dotDotIsRefused(typed: String) {
        #expect(ServerFolder.sftp(typed) == nil)
        #expect(ServerFolder.webDAV(typed) == nil)
    }

    private func sftp(_ folder: String, port: Int = 22) -> Connection {
        Connection(
            displayName: "NAS", endpoint: .sftp(host: "192.168.30.40", port: port), username: "pat",
            rootPath: folder, hostKey: "ssh-ed25519 AAAA")
    }

    /// The import row showed `192.168.30.40Documents`, with no slash between host and folder.
    @Test func theImportRowHasItsSlash() {
        let entry = DrivesFile.Entry(sftp("Documents"), credentials: Credentials(password: "x"))
        #expect(entry.shownAddress == "sftp://192.168.30.40/~/Documents")
        // The row also says it in words, because the two SFTP folders look alike.
        #expect(entry.shownLocation == "sftp://192.168.30.40/~/Documents\nDocuments, in the home folder")
        let top = DrivesFile.Entry(sftp("/Documents"), credentials: Credentials(password: "x"))
        #expect(top.shownLocation == "sftp://192.168.30.40/Documents\nDocuments, from the top of the server")
        #expect(ConnectionSummary.address(of: sftp("Documents", port: 2222)) == "sftp://192.168.30.40:2222/~/Documents")
        #expect(ConnectionSummary.address(of: sftp("/Documents")) == "sftp://192.168.30.40/Documents")
        #expect(ConnectionSummary.address(of: sftp("")) == "sftp://192.168.30.40")
        #expect(ConnectionSummary.address(of: sftp("/")) == "sftp://192.168.30.40/")
    }

    @Test(arguments: ["Documents", "/Documents", "", "/", "my files/2026", "/srv/my files"])
    func aShownAddressReadsBackAsTheSameDrive(folder: String) throws {
        let drive = sftp(folder)
        let read = try #require(ServerAddress(ConnectionSummary.address(of: drive)))
        #expect(read.endpoint == drive.endpoint)
        #expect(read.rootPath == folder)
    }

    @Test func aHomeFolderAndItsTildeFormsAreOneDestination() {
        let drive = sftp("Documents")
        for spelling in ["~/Documents", "/~/Documents", "Documents/", "~/Documents/"] {
            #expect(!sftp(spelling).requiresNewDrive(comparedTo: drive), "\(spelling)")
        }
    }

    @Test func anAbsoluteFolderIsntTheHomeFolder() {
        #expect(sftp("/Documents").requiresNewDrive(comparedTo: sftp("Documents")))
    }

    /// `/` is the server's top and blank is the login's home: on most servers, two places.
    @Test func theServersTopIsntTheHomeFolder() {
        #expect(sftp("/").requiresNewDrive(comparedTo: sftp("")))
        #expect(!sftp("~").requiresNewDrive(comparedTo: sftp("")))
    }

    @Test func aDoubledSlashOnWebDAVIsntAnotherDrive() throws {
        let one = Connection(displayName: "A", endpoint: .webDAV(url: try #require(URL(string: "https://example.com/a/b"))))
        let two = Connection(displayName: "B", endpoint: .webDAV(url: try #require(URL(string: "https://example.com//a//b/"))))
        #expect(!two.requiresNewDrive(comparedTo: one))
    }

    @Test func eachSFTPFolderSaysWhereItIs() {
        #expect(ServerFolder.shownPlace(of: sftp("Documents")) == "Documents, in the home folder")
        #expect(ServerFolder.shownPlace(of: sftp("/Documents")) == "Documents, from the top of the server")
        #expect(ServerFolder.shownPlace(of: sftp("")) == "The home folder")
        #expect(ServerFolder.shownPlace(of: sftp("/")) == "The top of the server")
        let webDAV = Connection(displayName: "W", endpoint: .webDAV(url: URL(string: "https://example.com/x")!))
        #expect(ServerFolder.shownPlace(of: webDAV) == nil)
    }

    @Test func theOtherReadingIsOfferedBothWays() {
        #expect(ServerFolder.otherReading(of: "Documents") == "/Documents")
        #expect(ServerFolder.otherReading(of: "~/Documents") == "/Documents")
        #expect(ServerFolder.otherReading(of: "/Documents") == "Documents")
        #expect(ServerFolder.otherReading(of: "") == nil)
        #expect(ServerFolder.otherReading(of: "/") == nil)
    }

    @Test(arguments: ["~/Documents", "/~/Documents", "Documents", " Documents/ "])
    func theFormStoresEachHomeSpellingAlike(typed: String) throws {
        var form = ConnectionForm()
        form.name = "NAS"
        form.kind = .sftp
        form.host = "192.168.30.40"
        form.path = typed
        let made = try #require(form.newConnection(isEncrypted: false))
        #expect(made.rootPath == "Documents")
        #expect(form.shownPlace == "Documents, in the home folder")
    }

    @Test func theFormSaysWhyAFolderCantBeUsed() {
        var form = ConnectionForm()
        form.name = "NAS"
        form.kind = .sftp
        form.host = "192.168.30.40"
        form.path = "docs/../etc"
        #expect(form.newConnection(isEncrypted: false) == nil)
        #expect(form.folderProblem == ServerFolder.refusal)
    }

    @Test func aPastedHomeAddressFillsTheHomeFolder() {
        var form = ConnectionForm()
        form.host = "sftp://192.168.30.40/~/Documents"
        form.tidyHost()
        #expect(form.kind == .sftp)
        #expect(form.path == "Documents")
    }

    @Test func aScannedCodesFolderIsChecked() throws {
        var bad = ConnectionSetup(connection: sftp("Documents"))
        bad.rootPath = "a/../../etc"
        #expect(throws: (any Error).self) { try ConnectionSetup(scanned: try bad.encoded()) }

        var spelled = ConnectionSetup(connection: sftp("Documents"))
        spelled.rootPath = "~/Documents"
        #expect(try ConnectionSetup(scanned: try spelled.encoded()).connection().rootPath == "Documents")
    }

    /// The folder is the test folder, because a test build refuses any other before comparing.
    @Test func anImportNeverAddsOneFolderTwiceWhateverItsSpelling() {
        let here = sftp("cloudmount-test")
        let entries = ["~/cloudmount-test", "/~/cloudmount-test/"].map { folder -> DrivesFile.Entry in
            var drive = sftp(folder)
            drive.displayName = "Other \(folder)"
            return DrivesFile.Entry(drive, credentials: Credentials(password: "x"))
        }
        let rows = DrivesFileImport.rows(for: entries, among: [here], on: .mac)
        #expect(rows.map(\.situation) == [.alreadyHere(here.id), .alreadyHere(here.id)])
    }

    @Test func anImportedFolderWithDotDotIsRefused() {
        let entry = DrivesFile.Entry(sftp("a/../cloudmount-test"), credentials: Credentials(password: "x"))
        let rows = DrivesFileImport.rows(for: [entry], among: [], on: .mac)
        #expect(rows.first?.situation == .notPossible(ServerFolder.refusal))
    }

    #if DEBUG
    /// Tidying happens before the test-folder guard, so no spelling can get past it.
    @Test(arguments: ["~/cloudmount-test", "/~/cloudmount-test/", " cloudmount-test "])
    func theTestFolderGuardSeesTheTidiedFolder(typed: String) throws {
        var form = ConnectionForm()
        form.name = "Test"
        form.kind = .sftp
        form.host = "127.0.0.1"
        form.path = typed
        let made = try #require(form.newConnection(isEncrypted: false))
        #expect(made.isTestDrive)
        #expect(made.rootPath == "cloudmount-test")
    }
    #endif
}
