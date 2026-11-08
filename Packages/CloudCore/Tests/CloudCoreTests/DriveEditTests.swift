// Apache 2 license - developer@infinitecontext.com

import CloudCore
import Foundation
import Testing

/// Editing a drive on the iPhone. A new name or sign-in changes it where it is. A new server,
/// folder or account makes a new drive, because everything kept for it describes the old place.
@Suite struct DriveEditTests {
    private func drive(
        _ name: String = "Work", host: String = "files.example.com", folder: String = "/dav/cloudmount-test",
        user: String = "me", encrypted: Bool = false
    ) -> Connection {
        var connection = Connection(
            displayName: name, endpoint: .webDAV(url: URL(string: "https://\(host)\(folder)")!),
            username: user, isEncrypted: encrypted)
        connection.vaultID = encrypted ? "vault" : nil
        connection.vaultRevision = encrypted ? 2 : nil
        return connection
    }

    private func sftp(host: String = "box.example.com", port: Int = 23) -> Connection {
        Connection(
            displayName: "Box", endpoint: .sftp(host: host, port: port), username: "me",
            rootPath: "/home/cloudmount-test", isEncrypted: false, hostKey: "ssh-ed25519 AAAA")
    }

    @Test func nothingChangedIsNothing() {
        let saved = drive()
        #expect(DriveEdit.change(from: saved, form: ConnectionForm(saved), signIn: SignInEdit(), among: [saved]) == .nothing)
    }

    @Test func aNewNameStaysTheSameDriveWithNothingToCheck() {
        let saved = drive()
        var form = ConnectionForm(saved)
        form.name = "Office"
        guard case .inPlace(let edited, let needsCheck) = DriveEdit.change(
            from: saved, form: form, signIn: SignInEdit(), among: [saved])
        else { Issue.record("a rename wasn't made in place"); return }
        #expect(edited.id == saved.id)
        #expect(edited.displayName == "Office")
        #expect(!needsCheck)
    }

    @Test func aNewPasswordStaysInPlaceAndIsChecked() {
        let saved = drive()
        guard case .inPlace(let edited, let needsCheck) = DriveEdit.change(
            from: saved, form: ConnectionForm(saved), signIn: SignInEdit(password: "new"), among: [saved])
        else { Issue.record("a new password wasn't made in place"); return }
        #expect(edited.id == saved.id)
        #expect(needsCheck)
    }

    /// Anything that points the drive somewhere else makes a new drive.
    @Test(arguments: ["host", "folder", "port", "protocol", "user"])
    func aNewPlaceIsANewDrive(_ field: String) {
        let saved = drive()
        var form = ConnectionForm(saved)
        switch field {
        case "host": form.host = "other.example.com"
        case "folder": form.path = "/elsewhere/cloudmount-test"
        case "port": form.port = "8443"
        case "protocol": form.kind = .http
        default: form.username = "someone-else"
        }
        guard case .move(let moved) = DriveEdit.change(from: saved, form: form, signIn: SignInEdit(), among: [saved])
        else { Issue.record("a new \(field) wasn't a new drive"); return }
        #expect(moved.id != saved.id)
        #expect(moved.displayName == saved.displayName)
    }

    /// The same server spelled another way is the same place. Rebuilding the address drops the
    /// vault pins, so the drive is connected again to set them back, never saved without them.
    @Test func aHostRetypedInAnotherCaseIsCheckedInPlace() {
        let saved = drive(encrypted: true)
        var form = ConnectionForm(saved)
        form.host = "FILES.example.com"
        guard case .inPlace(let edited, let needsCheck) = DriveEdit.change(
            from: saved, form: form, signIn: SignInEdit(), among: [saved])
        else { Issue.record("a respelled host was taken for a move"); return }
        #expect(edited.id == saved.id)
        #expect(needsCheck)
    }

    @Test func encryptionNeverChanges() {
        let saved = drive(encrypted: true)
        var form = ConnectionForm(saved)
        form.name = "Renamed"
        guard case .inPlace(let edited, _) = DriveEdit.change(from: saved, form: form, signIn: SignInEdit(), among: [saved])
        else { Issue.record("a rename wasn't made in place"); return }
        #expect(edited.isEncrypted)
        #expect(edited.vaultID == saved.vaultID)
    }

    /// A new SFTP server has to be trusted again: the old one's identity doesn't carry over.
    @Test func anotherSFTPServerIsTrustedAgain() {
        let saved = sftp()
        var form = ConnectionForm(saved)
        form.host = "new-box.example.com"
        guard case .move(let moved) = DriveEdit.change(from: saved, form: form, signIn: SignInEdit(), among: [saved])
        else { Issue.record("a new SFTP host wasn't a new drive"); return }
        #expect(moved.hostKey == nil)
    }

    @Test func anotherDrivesNameIsRefused() {
        let saved = drive()
        let other = drive("Home", host: "home.example.com")
        var form = ConnectionForm(saved)
        form.name = "Home"
        #expect(DriveEdit.change(from: saved, form: form, signIn: SignInEdit(), among: [saved, other])
            == .refused(DriveEdit.Clash.name.reason))
    }

    @Test func anotherDrivesPlaceIsRefused() {
        let saved = drive()
        let other = drive("Home", host: "home.example.com")
        var form = ConnectionForm(saved)
        form.host = "HOME.example.com"
        #expect(DriveEdit.change(from: saved, form: form, signIn: SignInEdit(), among: [saved, other])
            == .refused(DriveEdit.Clash.place.reason))
    }

    /// Adding uses the same check, so the phone can't hold two copies of one drive.
    @Test func addingADriveThatsAlreadyHereIsRefused() {
        let existing = drive()
        #expect(DriveEdit.clash(drive("Copy"), among: [existing]) == .place)
        #expect(DriveEdit.clash(drive(host: "other.example.com"), among: [existing]) == .name)
        #expect(DriveEdit.clash(drive("New", host: "other.example.com"), among: [existing]) == nil)
        // A drive never clashes with itself.
        #expect(DriveEdit.clash(existing, among: [existing]) == nil)
    }

    @Test func anEmptyNameOrAnAddressThatIsntOneIsRefused() {
        let saved = drive()
        var unnamed = ConnectionForm(saved)
        unnamed.name = "  "
        #expect(DriveEdit.change(from: saved, form: unnamed, signIn: SignInEdit(), among: [saved])
            == .refused(DriveEdit.noName))
        var broken = ConnectionForm(saved)
        broken.port = "99999"
        #expect(DriveEdit.change(from: saved, form: broken, signIn: SignInEdit(), among: [saved])
            == .refused(DriveEdit.badAddress))
    }

    #if DEBUG
    /// The guard every add path keeps in a test build, editing included.
    @Test func aTestBuildRefusesAFolderThatIsntTheTestFolder() {
        let saved = drive()
        var form = ConnectionForm(saved)
        form.path = "/dav/real-files"
        guard case .refused = DriveEdit.change(from: saved, form: form, signIn: SignInEdit(), among: [saved])
        else { Issue.record("a test build let a drive move to real files"); return }
    }
    #endif
}
