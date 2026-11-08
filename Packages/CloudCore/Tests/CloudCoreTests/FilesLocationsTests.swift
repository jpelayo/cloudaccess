// Apache 2 license - developer@infinitecontext.com

import CloudCore
import Foundation
import Testing

/// Which iPhone drives get a place in the Files app. Tests run as a debug build, so they see the
/// test-drive guard too.
@Suite struct FilesLocationsTests {
    private func drive(
        _ name: String = "Work", host: String = "example.invalid", folder: String = "cloudmount-test",
        encrypted: Bool = false
    ) -> Connection {
        Connection(
            displayName: name, endpoint: .webDAV(url: URL(string: "https://\(host)/\(folder)")!),
            isEncrypted: encrypted)
    }

    @Test func aPlainTestDriveIsShown() {
        #expect(FilesLocations.canShow(drive()))
    }

    /// Opening one would run scrypt, which alone needs most of what iOS gives the extension.
    @Test func anEncryptedDriveStaysInTheApp() {
        #expect(FilesLocations.absence(of: drive(encrypted: true)) == .encrypted)
    }

    /// A test build reaches only test folders, in Files as everywhere else.
    @Test func aTestBuildShowsOnlyTestDrives() {
        let real = drive(folder: "Documents")
        #expect(FilesLocations.absence(of: real) == .notATestDrive)
        #expect(FilesLocations.plan(drives: [real], locations: [:]).add.isEmpty)
    }

    @Test func missingLocationsAreAddedAndOrphansRemoved() {
        let shown = drive()
        let encrypted = drive("Vault", encrypted: true)
        let orphan = UUID().uuidString
        let plan = FilesLocations.plan(
            drives: [shown, encrypted], locations: [orphan: "Old", encrypted.id.uuidString: "Vault"])
        #expect(plan.add == [FilesLocations.Location(id: shown.id, name: "Work")])
        #expect(Set(plan.remove) == [orphan, encrypted.id.uuidString])
        #expect(plan.rename.isEmpty)
    }

    @Test func locationsThatMatchAreLeftAlone() {
        let shown = drive()
        let plan = FilesLocations.plan(drives: [shown], locations: [shown.id.uuidString: "Work"])
        #expect(plan == FilesLocations.Plan())
    }

    /// A new name reaches Files by adding the same identifier again. Removing first would throw
    /// away what Files holds for it.
    @Test func aRenamedDriveIsRenamedNotReplaced() {
        let shown = drive("Work, renamed")
        let plan = FilesLocations.plan(drives: [shown], locations: [shown.id.uuidString: "Work"])
        #expect(plan.rename == [FilesLocations.Location(id: shown.id, name: "Work, renamed")])
        #expect(plan.remove.isEmpty)
        #expect(plan.add.isEmpty)
    }

    /// Apple refuses a second location with a name already in use, so each gets one of its own.
    @Test func drivesWithTheSameNameGetNamesOfTheirOwn() {
        let first = drive(host: "one.invalid")
        let second = drive(host: "two.invalid")
        let third = drive(host: "two.invalid")
        let names = FilesLocations.names(for: [first, second, third])
        #expect(names[first.id] == "Work (one.invalid)")
        #expect(names[second.id] == "Work (two.invalid)")
        #expect(names[third.id] == "Work (two.invalid) 2")
        #expect(Set(names.values).count == 3)
    }

    @Test func aDriveWithAUniqueNameKeepsIt() {
        let names = FilesLocations.names(for: [drive("Work"), drive("Photos")])
        #expect(Set(names.values) == ["Work", "Photos"])
    }
}
