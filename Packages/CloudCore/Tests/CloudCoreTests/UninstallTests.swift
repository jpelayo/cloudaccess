// Apache 2 license - developer@infinitecontext.com

@testable import CloudCore
import Foundation
import Testing

/// Uninstalling removes every drive and everything the app keeps on the device, one checked step
/// at a time. A step passes only when what it removed is seen to be gone.
@Suite struct UninstallTests {
    private func drive(_ name: String, _ lifecycle: Connection.Lifecycle = .active, mounted: Bool = true) -> Connection {
        var connection = Connection(
            displayName: name, endpoint: .webDAV(url: URL(string: "https://example.invalid/\(name)")!))
        connection.lifecycle = lifecycle
        connection.isMounted = mounted
        return connection
    }

    private func removal(_ connection: Connection) -> Uninstall.Step {
        .removeDrive(id: connection.id, name: connection.displayName)
    }

    /// The Mac waits for uploads before anything goes, and turns launch at login off last,
    /// because turning it off ends the app.
    @Test func theMacsStepsComeInOrder() {
        let office = drive("Office")
        let photos = drive("Photos")
        let run = Uninstall.Run(platform: .mac, drives: [office, photos], orphanLocations: ["X"])
        #expect(run.steps == [
            .checkFirst, .waitForUploads, removal(office), removal(photos), .removeOrphanLocation(identifier: "X"),
            .stopBackgroundWork, .deleteLocalData, .deletePasswords, .confirmNothingLeft, .turnOffLaunchAtLogin,
        ])
    }

    /// The iPhone never uploads, checks nothing in the background and has no login item.
    @Test func theiPhonesStepsComeInOrder() {
        let office = drive("Office")
        let run = Uninstall.Run(platform: .phone, drives: [office], orphanLocations: [])
        #expect(run.steps == [.checkFirst, removal(office), .deleteLocalData, .deletePasswords, .confirmNothingLeft])
    }

    /// An ejected drive still has a password, and a half-added or half-removed one may still have
    /// a location. None of them may be left behind.
    @Test func everyDriveIsRemovedWhateverItsState() {
        let drives = [drive("A"), drive("B", mounted: false), drive("C", .adding), drive("D", .removing)]
        let run = Uninstall.Run(platform: .mac, drives: drives, orphanLocations: [])
        #expect(run.steps.filter { if case .removeDrive = $0 { true } else { false } } == drives.map(removal))
    }

    @Test func aLocationWithNoDriveIsFound() {
        let office = drive("Office")
        let orphans = Uninstall.orphanLocations(domains: [office.id.uuidString, "Z", "A"], drives: [office])
        #expect(orphans == ["A", "Z"])
    }

    @Test func theBarCountsPassedStepsAndTheWaitAsItGoes() {
        var run = Uninstall.Run(platform: .mac, drives: [drive("Office")], orphanLocations: [])
        // Launch at login turns off at Quit, so it isn't part of the bar.
        let counted = Double(run.steps.count - 1)
        #expect(run.fraction == 0)
        run.finish(.checkFirst, leftovers: [], note: nil, leftAs: .nothingChanged(.mac))
        #expect(run.fraction == 1 / counted)
        run.waiting(filesLeft: 4)
        run.waiting(filesLeft: 1)
        #expect(abs(run.fraction - 1.75 / counted) < 0.0001)
        run.waiting(filesLeft: 0)
        #expect(run.fraction == 2 / counted)
    }

    @Test func theWaitEndsOnlyWhenNothingIsLeftToSend() {
        var run = Uninstall.Run(platform: .mac, drives: [drive("Office")], orphanLocations: [])
        run.finish(.checkFirst, leftovers: [], note: nil, leftAs: .nothingChanged(.mac))
        run.waiting(filesLeft: 3)
        #expect(run.next == .waitForUploads)
        #expect(!run.state(of: .waitForUploads).isPassed)
        run.waiting(filesLeft: 0)
        #expect(run.state(of: .waitForUploads).isPassed)
    }

    /// The call can say it worked while the thing is still there. Only the check counts.
    @Test func aStepWhoseCheckFindsSomethingFails() {
        var run = Uninstall.Run(platform: .mac, drives: [], orphanLocations: [])
        run.begin(.deleteLocalData)
        run.finish(
            .deleteLocalData, leftovers: [.file("/tmp/x/Drives")], note: .deleted(items: 3), leftAs: .itemsLeft(.mac))
        guard case .failed(let reason, _) = run.state(of: .deleteLocalData) else {
            Issue.record("passed with something left")
            return
        }
        #expect(reason.english.contains("/tmp/x/Drives"))
        #expect(run.failedStep == .deleteLocalData)
    }

    @Test func aFailureStopsTheRunAndTryAgainStartsThere() {
        let office = drive("Office")
        let photos = drive("Photos")
        var run = Uninstall.Run(platform: .phone, drives: [office, photos], orphanLocations: [])
        run.finish(.checkFirst, leftovers: [], note: nil, leftAs: .nothingChanged(.phone))
        run.begin(removal(office))
        run.fail(removal(office), reason: .didNotStop, leftAs: .driveStillThere(.phone))
        #expect(run.next == removal(office))
        #expect(run.state(of: removal(photos)) == .pending)
        #expect(!run.isFinished)
        run.tryAgain()
        #expect(run.failedStep == nil)
        #expect(run.state(of: removal(office)) == .pending)
        #expect(run.next == removal(office))
    }

    /// What the last check finds belongs to an earlier step, so Try Again runs those again.
    @Test func aFailedLastCheckRunsTheRemovalsAgain() {
        let office = drive("Office")
        var run = Uninstall.Run(platform: .mac, drives: [office], orphanLocations: [])
        for step in run.steps where step != .turnOffLaunchAtLogin && step != .confirmNothingLeft {
            run.finish(step, leftovers: [], note: nil, leftAs: .nothingChanged(.mac))
        }
        run.finish(.confirmNothingLeft, leftovers: [.passwords], leftAs: .passwordsLeft)
        run.tryAgain()
        #expect(run.next == removal(office))
        #expect(run.state(of: .checkFirst).isPassed)
        #expect(run.state(of: .waitForUploads).isPassed)
        for step in [removal(office), .stopBackgroundWork, .deleteLocalData, .deletePasswords, .confirmNothingLeft] {
            #expect(run.state(of: step) == .pending)
        }
    }

    /// The temporary folder is shared with the system, so only what the app made goes.
    @Test func onlyTheAppsOwnTemporaryItemsAreChosen() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("UninstallTemporary-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let sent = UUID().uuidString
        for name in [sent, "CloudWanderer log 2026-11-10.txt", "com.apple.something", "notes.txt"] {
            try Data("x".utf8).write(to: folder.appendingPathComponent(name))
        }
        let chosen = Uninstall.temporaryItems(in: folder).map(\.lastPathComponent)
        #expect(Set(chosen) == [sent, "CloudWanderer log 2026-11-10.txt"])
    }

    /// Cancel is only offered while nothing has been removed.
    @Test func nothingHasChangedUntilTheFirstRemovalBegins() {
        let office = drive("Office")
        var run = Uninstall.Run(platform: .mac, drives: [office], orphanLocations: [])
        run.finish(.checkFirst, leftovers: [], note: nil, leftAs: .nothingChanged(.mac))
        run.waiting(filesLeft: 2)
        #expect(!run.hasChangedAnything)
        run.waiting(filesLeft: 0)
        run.begin(removal(office))
        #expect(run.hasChangedAnything)
    }

    @Test func itsFinishedWhenEveryStepButLaunchAtLoginHasPassed() {
        var run = Uninstall.Run(platform: .mac, drives: [], orphanLocations: [])
        for step in run.steps where step != .turnOffLaunchAtLogin {
            run.finish(step, leftovers: [], note: nil, leftAs: .nothingChanged(.mac))
        }
        #expect(run.isFinished)
        #expect(run.fraction == 1)
        #expect(run.next == .turnOffLaunchAtLogin)
    }

    /// The report replaces the log, which is deleted. It names drives and what happened to them,
    /// and nothing that opens one.
    @Test func theReportHoldsNoSecretAndNoServer() {
        let office = drive("Office")
        var run = Uninstall.Run(platform: .mac, drives: [office], orphanLocations: [])
        run.finish(.checkFirst, leftovers: [], note: .found(drives: 1), leftAs: .nothingChanged(.mac))
        run.begin(removal(office))
        run.fail(
            removal(office), reason: Uninstall.Line(english: "refused: token=abc123", shown: "refused"),
            leftAs: .driveStillThere(.mac))
        let report = run.report()
        #expect(report.contains("Office"))
        #expect(report.contains("Failed"))
        #expect(!report.contains("abc123"))
        #expect(!report.contains("example.invalid"))
    }

    /// Files macOS kept are the one thing a person may still need, and the list of them is
    /// deleted with the rest, so the report carries their paths.
    @Test func theReportListsWhereKeptFilesAre() {
        var run = Uninstall.Run(platform: .mac, drives: [], orphanLocations: [])
        run.keep(filesAt: "/Users/someone/Library/Kept/Office")
        #expect(run.keptFiles == ["/Users/someone/Library/Kept/Office"])
        #expect(run.report().contains("/Users/someone/Library/Kept/Office"))
    }

    @Test func theReportIsEnglishAndPluralsReadRight() {
        #expect(Uninstall.Line.found(drives: 1).english == "Found 1 drive.")
        #expect(Uninstall.Line.found(drives: 2).english == "Found 2 drives.")
        #expect(Uninstall.Line.waiting(files: 1).english == "Waiting for 1 file to upload.")
    }
}

/// Deleting what a store keeps, for an uninstall. It removes only what it knows it made, and then
/// looks again.
@Suite struct DriveStoreUninstallTests {
    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("DriveStoreUninstallTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test func everythingItKeepsIsDeletedAndNothingElse() throws {
        let folder = try temporaryFolder()
        let store = DriveStore(directory: folder)
        let id = UUID()
        try store.save(Connection(displayName: "Work", endpoint: .webDAV(url: URL(string: "https://example.invalid")!)))
        try store.addPreserved(.init(driveName: "Work", path: "/somewhere"))
        _ = try store.deviceID()
        let database = try store.databaseURL(for: id)
        for suffix in ["", "-wal", ".rebuilding", ".partial"] {
            try Data("x".utf8).write(to: URL(fileURLWithPath: database.path + suffix))
        }
        store.diagnostics.record("hello")
        try Data("x".utf8).write(to: folder.appendingPathComponent("diagnostics.log"))
        let notes = store.filesNotesURL(for: id)
        try FileManager.default.createDirectory(at: notes.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: notes)
        try Data("x".utf8).write(to: store.memoryReportURL)
        // Not the store's: it stays.
        let someoneElses = folder.appendingPathComponent("Library")
        try FileManager.default.createDirectory(at: someoneElses, withIntermediateDirectories: true)

        let outcome = store.deleteEverything()
        #expect(outcome.left.isEmpty)
        #expect(outcome.deleted > 0)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(remaining == ["Library"])
    }

    @Test func whatCantBeDeletedIsNamed() throws {
        let folder = try temporaryFolder()
        let store = DriveStore(directory: folder)
        let drives = try store.databaseURL(for: UUID()).deletingLastPathComponent()
        try Data("x".utf8).write(to: drives.appendingPathComponent("stuck"))
        // A folder that can't be written to keeps what's in it.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: drives.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: drives.path) }
        let outcome = store.deleteEverything()
        #expect(outcome.left.contains(drives.path))
    }

    /// The check after removing a drive mustn't make the folder it's checking.
    @Test func lookingForADrivesDatabaseCreatesNothing() throws {
        let folder = try temporaryFolder()
        let store = DriveStore(directory: folder)
        let id = UUID()
        #expect(store.databaseFiles(for: id).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("Drives").path))
        let database = try store.databaseURL(for: id)
        try Data("x".utf8).write(to: database)
        try Data("x".utf8).write(to: URL(fileURLWithPath: database.path + ".partial"))
        try Data("x".utf8).write(to: database.deletingLastPathComponent().appendingPathComponent("\(UUID().uuidString).sqlite"))
        #expect(store.databaseFiles(for: id) == [database.path, database.path + ".partial"])
    }

    @Test func aStoreWithNothingInItHasNothingLeft() throws {
        let store = DriveStore(directory: try temporaryFolder())
        let outcome = store.deleteEverything()
        #expect(outcome.left.isEmpty)
        #expect(outcome.deleted == 0)
    }
}
