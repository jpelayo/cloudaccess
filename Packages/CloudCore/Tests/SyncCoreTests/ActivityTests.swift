// Apache 2 license - developer@infinitecontext.com

import CloudCore
import Foundation
import SyncCore
import Testing

@Suite struct ActivityTests {
    private func makeStore() throws -> SyncStore {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ActivityTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try SyncStore(url: folder.appendingPathComponent("state.sqlite"))
    }

    /// The list stays small, and the totals still say how much has really been done.
    @Test func theListIsCappedAndTheTotalsArent() throws {
        let store = try makeStore()
        for index in 0..<(SyncStore.activityLimit + 50) {
            try store.noteFinished(.uploaded, name: "file \(index)", size: 1)
        }
        let recent = try store.recentActivity()
        #expect(recent.count == SyncStore.activityLimit)
        #expect(recent.first?.name == "file \(SyncStore.activityLimit + 49)")
        #expect(try store.totals().uploaded == SyncStore.activityLimit + 50)
    }

    @Test func totalsSayWhenTheyStarted() throws {
        let store = try makeStore()
        let first = Date(timeIntervalSince1970: 1_000_000)
        try store.noteFinished(.uploaded, name: "a", size: 1, now: first)
        try store.noteFinished(.downloaded, name: "b", size: 1, now: first.addingTimeInterval(60))
        let totals = try store.totals()
        #expect(totals.since == first)
        #expect(totals.uploaded == 1)
        #expect(totals.downloaded == 1)
    }

    @Test func aNewDriveHasNoTotals() throws {
        let totals = try makeStore().totals()
        #expect(totals.since == nil)
        #expect(totals.uploaded == 0)
    }

    /// A transfer proves something is moving, so one left by a process that died mustn't go on
    /// proving it.
    @Test func aTransferThatStoppedReportingIsntLive() throws {
        let store = try makeStore()
        let start = Date(timeIntervalSince1970: 1_000_000)
        try store.recordTransfer(
            id: "a", name: "big.mov", direction: .upload, done: 0, total: 100, started: start, now: start)
        #expect(try store.liveTransfers(now: start.addingTimeInterval(60)).count == 1)
        #expect(try store.liveTransfers(now: start.addingTimeInterval(120)).isEmpty)
    }

    @Test func aTransferSaysHowFarItsGot() throws {
        let store = try makeStore()
        let start = Date(timeIntervalSince1970: 1_000_000)
        let id = "a"
        try store.recordTransfer(
            id: id, name: "big.mov", direction: .upload, done: 0, total: 100, started: start, now: start)
        try store.recordTransfer(
            id: id, name: "big.mov", direction: .upload, done: 40, total: 100, started: start,
            now: start.addingTimeInterval(10))

        let transfer = try #require(try store.liveTransfers(now: start.addingTimeInterval(10)).first)
        #expect(transfer.name == "big.mov")
        #expect(transfer.done == 40)
        #expect(transfer.bytesPerSecond == 4)

        try store.finishTransfer(id: id)
        #expect(try store.liveTransfers(now: start.addingTimeInterval(10)).isEmpty)
    }

    private final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_000_000)
    }

    /// The engine reports constantly, and every write here reaches the disk.
    @Test func aReporterWritesAboutOnceASecond() throws {
        let store = try makeStore()
        let clock = Clock()
        let reporter = TransferReporter(
            store: store, name: "big.mov", direction: .upload, total: 100, clock: { clock.now })

        clock.now.addTimeInterval(0.2)
        reporter.update(10)
        #expect(try store.liveTransfers(now: clock.now).first?.done == 10)

        clock.now.addTimeInterval(0.5)
        reporter.update(15)
        #expect(try store.liveTransfers(now: clock.now).first?.done == 10)

        clock.now.addTimeInterval(1)
        reporter.update(20)
        #expect(try store.liveTransfers(now: clock.now).first?.done == 20)

        // The commit that follows an upload is a new engine call, counting from nothing.
        clock.now.addTimeInterval(1)
        reporter.update(0)
        #expect(try store.liveTransfers(now: clock.now).first?.done == 20)

        reporter.finish()
        #expect(try store.liveTransfers(now: clock.now).isEmpty)
    }

    /// macOS hands over more files than may upload at once, and the rest wait their turn. One that
    /// waited longer than a dead process's record lasts was cleared as one, and then moved unseen,
    /// so a drive sending 15 MB/s said nothing was moving.
    @Test func anUploadThatWaitedItsTurnStillShows() throws {
        let store = try makeStore()
        let clock = Clock()
        let waited = TransferReporter(
            store: store, name: "waited.mov", direction: .upload, total: 100, clock: { clock.now })

        clock.now.addTimeInterval(100)
        let next = TransferReporter(
            store: store, name: "next.mov", direction: .upload, total: 100, clock: { clock.now })
        next.update(1)

        clock.now.addTimeInterval(1)
        waited.update(5)
        let live = try store.liveTransfers(now: clock.now)
        #expect(live.first { $0.name == "waited.mov" }?.done == 5)
    }

    /// A file waiting its turn isn't moving, and its speed counts from when it started.
    @Test func aWaitingTransferIsntShownUntilItStarts() throws {
        let store = try makeStore()
        let clock = Clock()
        let reporter = TransferReporter(
            store: store, name: "big.mov", direction: .upload, total: 100, clock: { clock.now })
        #expect(try store.liveTransfers(now: clock.now).isEmpty)

        clock.now.addTimeInterval(30)
        reporter.update(0)
        let transfer = try #require(try store.liveTransfers(now: clock.now).first)
        #expect(transfer.started == clock.now)
    }

    /// An upload and its commit are two engine calls, and the second can wait too.
    @Test func aRecordClearedBetweenEngineCallsComesBack() throws {
        let store = try makeStore()
        let clock = Clock()
        let reporter = TransferReporter(
            store: store, name: "big.mov", direction: .upload, total: 100, clock: { clock.now })
        clock.now.addTimeInterval(0.5)
        reporter.update(10)
        let started = clock.now

        clock.now.addTimeInterval(100)
        let other = TransferReporter(
            store: store, name: "other.mov", direction: .upload, total: 100, clock: { clock.now })
        other.update(1)

        clock.now.addTimeInterval(1)
        reporter.update(0)
        let transfer = try #require(try store.liveTransfers(now: clock.now).first { $0.name == "big.mov" })
        #expect(transfer.done == 10)
        #expect(transfer.started == started)
    }

    /// The engine's last report can arrive after the transfer has ended.
    @Test func aLateReportAfterFinishingLeavesNothing() throws {
        let store = try makeStore()
        let clock = Clock()
        let reporter = TransferReporter(
            store: store, name: "big.mov", direction: .upload, total: 100, clock: { clock.now })
        clock.now.addTimeInterval(1)
        reporter.update(10)
        reporter.finish()

        clock.now.addTimeInterval(1)
        reporter.update(20)
        #expect(try store.liveTransfers(now: clock.now).isEmpty)
    }

    @Test func clearingAFailureAlsoForgetsItsAttempts() throws {
        let store = try makeStore()
        try store.noteFailedAttempt(id: "a", name: "a", message: "No", canHold: true)
        #expect(try store.attempts().count == 1)
        try store.clearFailure(id: "a")
        #expect(try store.attempts().isEmpty)
    }

    /// The app checks each of these against the disk, so a rename leaves nothing behind.
    @Test func unsentFilesIncludeThoseOnlyBeingRetried() throws {
        let store = try makeStore()
        let failed = SyncFailure.unsentID(name: "failed.txt", parentID: SyncItem.rootID)
        let retried = SyncFailure.unsentID(name: "retried.txt", parentID: SyncItem.rootID)
        try store.recordFailure(id: failed, name: "failed.txt", message: "No")
        try store.noteFailedAttempt(id: failed, name: "failed.txt", message: "No", canHold: true)
        try store.noteFailedAttempt(id: retried, name: "retried.txt", message: "No", canHold: true)
        try store.noteFailedAttempt(id: "an-item", name: "on the server", message: "No", canHold: true)

        let names = try store.unsentFiles().map(\.name).sorted()

        #expect(names == ["failed.txt", "retried.txt"])
    }

    /// Items and files that never reached the server are told apart by this, in both directions.
    @Test func anUnsentIDLeadsBackToItsFolder() throws {
        let store = try makeStore()
        let id = SyncFailure.unsentID(name: "doc.txt", parentID: SyncItem.rootID)
        try store.recordFailure(id: id, name: "doc.txt", message: "No")
        let failure = try #require(try store.failures().first)
        #expect(failure.isUnsentFile)
        #expect(store.path(of: failure) == RemotePath("/doc.txt"))
    }
}
