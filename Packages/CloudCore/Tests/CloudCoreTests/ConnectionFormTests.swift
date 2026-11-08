// Apache 2 license - developer@infinitecontext.com

import Foundation
import Testing
@testable import CloudCore

/// The same place written differently must never pass for a second drive, because two drives on
/// one folder would be two databases and two sets of claims over the same files.
@Suite struct DriveIdentityTests {
    private func webDAV(_ address: String, root: String = "") -> Connection {
        Connection(displayName: "Drive", endpoint: .webDAV(url: URL(string: address)!), rootPath: root)
    }

    @Test func spellingDoesntMakeAnotherDrive() {
        let drive = webDAV("https://files.example.com/work")
        #expect(!webDAV("https://FILES.example.com/work").requiresNewDrive(comparedTo: drive))
        #expect(!webDAV("https://files.example.com/work/").requiresNewDrive(comparedTo: drive))
        #expect(!webDAV("https://files.example.com:443/work").requiresNewDrive(comparedTo: drive))
        #expect(!webDAV("HTTPS://files.example.com/work").requiresNewDrive(comparedTo: drive))
    }

    @Test func anotherPlaceIsAnotherDrive() {
        let drive = webDAV("https://files.example.com/work")
        #expect(webDAV("https://files.example.com/home").requiresNewDrive(comparedTo: drive))
        #expect(webDAV("https://files.example.com:8443/work").requiresNewDrive(comparedTo: drive))
        #expect(webDAV("http://files.example.com/work").requiresNewDrive(comparedTo: drive))
        #expect(webDAV("https://other.example.com/work").requiresNewDrive(comparedTo: drive))
    }

    /// Paths on a server are case-sensitive, so only the host folds.
    @Test func aFolderInADifferentCaseIsAnotherDrive() {
        let drive = webDAV("https://files.example.com/work")
        #expect(webDAV("https://files.example.com/Work").requiresNewDrive(comparedTo: drive))
    }

    @Test func sftpFoldsTheHostAndTheTrailingSlash() {
        let drive = Connection(displayName: "A", endpoint: .sftp(host: "box.example.com", port: 23), rootPath: "/files")
        let same = Connection(displayName: "B", endpoint: .sftp(host: "BOX.example.com", port: 23), rootPath: "/files/")
        let other = Connection(displayName: "C", endpoint: .sftp(host: "box.example.com", port: 22), rootPath: "/files")
        #expect(!same.requiresNewDrive(comparedTo: drive))
        #expect(other.requiresNewDrive(comparedTo: drive))
    }

    /// What a person chose and what a server allows are separate, so turning the switch off can't
    /// quietly allow writes to a server that can't take them.
    @Test func aServerLimitStandsApartFromThePersonsChoice() {
        var drive = webDAV("https://files.example.com/work")
        #expect(!drive.isReadOnly)
        drive.serverIsReadOnly = true
        #expect(drive.isReadOnly)
        #expect(!drive.settings.isReadOnly)
        drive.settings.isReadOnly = true
        drive.settings.isReadOnly = false
        #expect(drive.isReadOnly)
    }
}

@Suite struct ConnectionFormTests {
    private func webDAV(_ address: String) throws -> Connection {
        let url = try #require(URL(string: address))
        return Connection(displayName: "Work", endpoint: .webDAV(url: url), username: "someone")
    }

    private func sftp(path: String = "/data") -> Connection {
        Connection(
            displayName: "Work", endpoint: .sftp(host: "example.com", port: 23), username: "someone",
            rootPath: path, hostKey: "ssh-ed25519 AAAA")
    }

    @Test(arguments: [
        "https://example.com/cloudmount-test",
        "https://example.com:8443/cloudmount-test",
        "http://127.0.0.1:18080/cloudmount-test",
        "https://example.com/cloudmount-test/",
        "https://example.com/my%20files/cloudmount-test",
        "https://example.com",
    ])
    func anUntouchedFormChangesNothingOnWebDAV(address: String) throws {
        let connection = try webDAV(address)
        #expect(ConnectionForm(connection).applied(to: connection) == connection)
    }

    @Test(arguments: ["/data", "docs", "/my files"])
    func anUntouchedFormChangesNothingOnSFTP(path: String) {
        let connection = sftp(path: path)
        #expect(ConnectionForm(connection).applied(to: connection) == connection)
    }

    @Test func theFieldsShowWhatTheDriveUses() throws {
        let form = ConnectionForm(try webDAV("http://127.0.0.1:18080/my%20files/cloudmount-test"))
        #expect(form.kind == .http)
        #expect(form.host == "127.0.0.1")
        #expect(form.port == "18080")
        #expect(form.path == "/my files/cloudmount-test")
        #expect(form.username == "someone")
        #expect(ConnectionForm(sftp()).port == "23")
    }

    @Test func aNewNameStaysTheSameDrive() throws {
        let connection = try webDAV("https://example.com/cloudmount-test")
        var form = ConnectionForm(connection)
        form.name = "  Renamed  "
        let edited = try #require(form.applied(to: connection))
        #expect(edited.displayName == "Renamed")
        #expect(!edited.requiresNewDrive(comparedTo: connection))
    }

    @Test func aNewHostIsANewLocationAndDropsWhatWasPinned() throws {
        var connection = sftp()
        connection.vaultID = "vault"
        connection.vaultRevision = 3
        var form = ConnectionForm(connection)
        form.host = "other.example.com"
        let edited = try #require(form.applied(to: connection))
        #expect(edited.requiresNewDrive(comparedTo: connection))
        #expect(edited.endpoint == .sftp(host: "other.example.com", port: 23))
        #expect(edited.hostKey == nil)
        #expect(edited.vaultID == nil)
        #expect(edited.vaultRevision == nil)
    }

    @Test func anotherFolderOnTheSameServerKeepsItsTrust() throws {
        let connection = sftp()
        var form = ConnectionForm(connection)
        form.path = "/elsewhere"
        let edited = try #require(form.applied(to: connection))
        #expect(edited.requiresNewDrive(comparedTo: connection))
        #expect(edited.rootPath == "/elsewhere")
        #expect(edited.hostKey == connection.hostKey)
    }

    @Test func aNewUserIsANewLocation() throws {
        let connection = try webDAV("https://example.com/cloudmount-test")
        var form = ConnectionForm(connection)
        form.username = "someone-else"
        let edited = try #require(form.applied(to: connection))
        #expect(edited.username == "someone-else")
        #expect(edited.requiresNewDrive(comparedTo: connection))
    }

    @Test func aFolderWithSpacesMakesAValidAddress() throws {
        let connection = try webDAV("https://example.com/cloudmount-test")
        var form = ConnectionForm(connection)
        form.path = "/my files/cloudmount-test"
        let edited = try #require(form.applied(to: connection))
        #expect(edited.isTestDrive)
        #expect(ConnectionForm(edited).path == "/my files/cloudmount-test")
    }

    @Test func anSFTPFolderInTheHomeFolderStaysThere() throws {
        let connection = sftp(path: "/data")
        var form = ConnectionForm(connection)
        form.path = "docs"
        let edited = try #require(form.applied(to: connection))
        #expect(edited.rootPath == "docs")
    }

    @Test func aChangeOfProtocolChangesTheEndpoint() throws {
        let connection = try webDAV("https://example.com/cloudmount-test")
        var form = ConnectionForm(connection)
        form.kind = .sftp
        form.port = "23"
        let edited = try #require(form.applied(to: connection))
        #expect(edited.endpoint == .sftp(host: "example.com", port: 23))
        #expect(edited.rootPath == "/cloudmount-test")
    }

    @Test(arguments: ["", "  ", "user@example.com", "bad host", "example.com/path", "example.com?a=b", "example.com#a"])
    func aBadHostIsRefused(host: String) throws {
        let connection = try webDAV("https://example.com/cloudmount-test")
        var form = ConnectionForm(connection)
        form.host = host
        #expect(form.applied(to: connection) == nil)
    }

    @Test(arguments: ["0", "65536", "abc", "-1", "80a"])
    func aBadPortIsRefused(port: String) throws {
        let connection = try webDAV("https://example.com/cloudmount-test")
        var form = ConnectionForm(connection)
        form.port = port
        #expect(form.applied(to: connection) == nil)
    }

    @Test func aFolderCantCarryAQueryOrAFragment() throws {
        let connection = try webDAV("https://example.com/cloudmount-test")
        var form = ConnectionForm(connection)
        form.path = "/folder?x=1#y"
        let edited = try #require(form.applied(to: connection))
        #expect(ConnectionForm(edited).path == "/folder?x=1#y")
        guard case .webDAV(let url) = edited.endpoint else {
            Issue.record("Expected a WebDAV address")
            return
        }
        #expect(url.query == nil)
        #expect(url.fragment == nil)
    }

    @Test func anEmptyNameIsRefused() throws {
        let connection = try webDAV("https://example.com/cloudmount-test")
        var form = ConnectionForm(connection)
        form.name = "   "
        #expect(form.applied(to: connection) == nil)
    }

    @Test func onlyANewHTTPAddressNeedsConsent() throws {
        let secure = try webDAV("https://example.com/cloudmount-test")
        var form = ConnectionForm(secure)
        #expect(!form.needsInsecureConsent(comparedTo: secure))
        form.kind = .http
        #expect(form.needsInsecureConsent(comparedTo: secure))

        let existing = try webDAV("http://127.0.0.1:18080/cloudmount-test")
        #expect(!ConnectionForm(existing).needsInsecureConsent(comparedTo: existing))
    }
}

@Suite struct SignInEditTests {
    private let saved = Credentials(
        password: "old", privateKeyPEM: "old key", privateKeyPassphrase: "old phrase", vaultPassword: "vault")

    @Test func blankFieldsKeepWhatsSaved() {
        let edit = SignInEdit()
        #expect(edit.isEmpty)
        let result = edit.applied(to: saved)
        #expect(result.password == "old")
        #expect(result.privateKeyPEM == "old key")
        #expect(result.privateKeyPassphrase == "old phrase")
        #expect(result.vaultPassword == "vault")
    }

    @Test func aNewPasswordOnlyReplacesThePassword() {
        let edit = SignInEdit(password: "new")
        #expect(!edit.isEmpty)
        let result = edit.applied(to: saved)
        #expect(result.password == "new")
        #expect(result.privateKeyPEM == "old key")
        #expect(result.vaultPassword == "vault")
    }

    @Test func aNewKeyDoesntInheritTheOldPassphrase() {
        let result = SignInEdit(privateKeyPEM: "new key").applied(to: saved)
        #expect(result.privateKeyPEM == "new key")
        #expect(result.privateKeyPassphrase == nil)
        #expect(result.password == "old")
    }

    @Test func aNewKeyCanBringItsPassphrase() {
        let result = SignInEdit(privateKeyPEM: "new key", privateKeyPassphrase: "new phrase").applied(to: saved)
        #expect(result.privateKeyPassphrase == "new phrase")
    }
}

/// The add form: a person gives a host, or pastes a whole address, and either has to work.
@Suite struct NewDriveFormTests {
    private func tidied(host: String, kind: ConnectionForm.Kind = .https, username: String = "") -> ConnectionForm {
        var form = ConnectionForm()
        form.kind = kind
        form.host = host
        form.username = username
        form.tidyHost()
        return form
    }

    private func named(_ form: ConnectionForm) -> ConnectionForm {
        var named = form
        named.name = "Work"
        return named
    }

    @Test func aPlainHostNeedsNoScheme() throws {
        let connection = try #require(named(tidied(host: "box.example.com")).newConnection(isEncrypted: false))
        #expect(connection.endpoint == .webDAV(url: try #require(URL(string: "https://box.example.com"))))
    }

    @Test func aPastedAddressFillsTheFields() {
        let form = tidied(host: " https://box.example.com:8443/team/files/ ")
        #expect(form.kind == .https)
        #expect(form.host == "box.example.com")
        #expect(form.port == "8443")
        #expect(form.path == "/team/files")
    }

    @Test func aPastedAddressSetsTheProtocol() {
        #expect(tidied(host: "http://box.example.com").kind == .http)
        #expect(tidied(host: "sftp://box.example.com:23/docs").kind == .sftp)
        #expect(tidied(host: "sftp://box.example.com:23/docs").port == "23")
    }

    @Test func aHostWithAPortOrAFolderKeepsTheChosenProtocol() {
        let port = tidied(host: "box.example.com:2022", kind: .sftp)
        #expect(port.kind == .sftp)
        #expect(port.host == "box.example.com")
        #expect(port.port == "2022")
        let folder = tidied(host: "box.example.com/team", kind: .https)
        #expect(folder.host == "box.example.com")
        #expect(folder.path == "/team")
    }

    @Test func anAddressWithAUserFillsItInButNeverKeepsAPassword() {
        let form = tidied(host: "sftp://sam:secret@box.example.com/docs")
        #expect(form.host == "box.example.com")
        #expect(form.username == "sam")
        #expect(!"\(form)".contains("secret"))
        #expect(tidied(host: "sftp://sam@box.example.com", username: "kept").username == "kept")
    }

    @Test func anIPv6AddressIsLeftAlone() {
        #expect(tidied(host: "fd7a:115c:a1e0::1").host == "fd7a:115c:a1e0::1")
    }

    @Test func somethingThatIsNotAnAddressIsLeftForTheChecks() {
        var form = named(tidied(host: "ftp://box.example.com"))
        #expect(form.host == "ftp://box.example.com")
        #expect(form.newConnection(isEncrypted: false) == nil)
        form.host = ""
        #expect(form.newConnection(isEncrypted: false) == nil)
    }

    @Test func aNewDriveNeedsAName() {
        #expect(tidied(host: "box.example.com").newConnection(isEncrypted: false) == nil)
        #expect(tidied(host: "box.example.com").browsingConnection() != nil)
    }

    @Test func aChosenFolderBecomesThePathOnEachProtocol() throws {
        let folder = try #require(RemotePath("team/my files"))
        #expect(tidied(host: "box.example.com").folderField(for: folder) == "/team/my files")
        #expect(tidied(host: "box.example.com", kind: .sftp).folderField(for: folder) == "team/my files")
    }

    @Test func aFolderChosenFromInsideAnotherKeepsItsParent() throws {
        var form = tidied(host: "box.example.com")
        form.path = "/cloudmount-test/"
        #expect(form.folderField(for: try #require(RemotePath("inside"))) == "/cloudmount-test/inside")
        #expect(form.folderField(for: .root) == "/cloudmount-test/")
    }

    @Test func aChosenFolderReachesTheConnection() throws {
        var webDAV = named(tidied(host: "box.example.com"))
        webDAV.path = webDAV.folderField(for: try #require(RemotePath("my files")))
        let connection = try #require(webDAV.newConnection(isEncrypted: true))
        #expect(connection.endpoint == .webDAV(url: try #require(URL(string: "https://box.example.com/my%20files"))))

        var sftp = named(tidied(host: "box.example.com", kind: .sftp))
        sftp.port = "23"
        sftp.path = sftp.folderField(for: try #require(RemotePath("docs")))
        let secure = try #require(sftp.newConnection(isEncrypted: false))
        #expect(secure.endpoint == .sftp(host: "box.example.com", port: 23))
        #expect(secure.rootPath == "docs")
    }

    @Test func aDrivesOwnFolderIsNamedAfterIt() {
        var form = tidied(host: "box.example.com")
        form.name = " Hetzner / Work "
        #expect(form.ownFolderName == "Hetzner - Work")
        form.name = ".."
        #expect(form.ownFolderName.isEmpty)
        form.name = ".cloudmount"
        #expect(form.ownFolderName.isEmpty)
    }

    @Test func browsingStartsAtTheTopWhateverTheFolderSays() {
        var form = tidied(host: "box.example.com")
        form.path = "/team"
        #expect(form.atTopFolder.path.isEmpty)
    }
}
