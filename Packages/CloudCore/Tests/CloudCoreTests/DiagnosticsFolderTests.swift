// Apache 2 license - developer@infinitecontext.com

import CloudCore
import Foundation
import Testing

/// The log is what a person opens from the Information page, so it has a folder of its own: beside
/// the drives' settings and databases, one wrong move in Finder could damage them. It can't be
/// allowed to grow either, because nobody will ever think to clean it.
@Suite struct DiagnosticsFolderTests {
    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiagnosticsFolderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func lines(of log: Diagnostics) throws -> [String] {
        try String(contentsOf: log.file, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    private func names(in folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    /// A log left by an earlier day, because the date on the file is what decides.
    private func plant(_ name: String, in folder: URL, daysOld: Double, bytes: Int = 8) throws {
        let file = folder.appendingPathComponent(name)
        try Data(repeating: 0x61, count: bytes).write(to: file)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-daysOld * 86_400)], ofItemAtPath: file.path)
    }

    // MARK: Where it is

    @Test func theLogHasAFolderOfItsOwn() throws {
        let shared = try temporaryFolder()
        let log = DriveStore(directory: shared).diagnostics
        #expect(log.folder == shared.appendingPathComponent("Logs"))
        #expect(log.file.path.hasPrefix(log.folder.path + "/"))
    }

    @Test func aFolderThatIsntThereYetIsMade() throws {
        let log = Diagnostics(directory: try temporaryFolder().appendingPathComponent("Logs"))
        log.record("first line")
        #expect(try lines(of: log).count == 1)
    }

    @Test func whatAnOlderBuildWroteComesAcross() throws {
        let shared = try temporaryFolder()
        try Data("current\n".utf8).write(to: shared.appendingPathComponent("diagnostics.log"))
        try Data("older\n".utf8).write(to: shared.appendingPathComponent("diagnostics.old.log"))
        let log = DriveStore(directory: shared).diagnostics

        log.record("new line")

        let text = log.exportedText(header: "CloudAccess")
        #expect(text.contains("older"))
        #expect(text.contains("current"))
        #expect(text.contains("new line"))
        #expect(!FileManager.default.fileExists(atPath: shared.appendingPathComponent("diagnostics.log").path))
        #expect(!FileManager.default.fileExists(atPath: shared.appendingPathComponent("diagnostics.old.log").path))
    }

    /// Several files fail at once, in the app and in each drive's extension. A line overwriting
    /// another would lose exactly what someone opened the log to read.
    @Test func linesWrittenTogetherAreAllKept() throws {
        let log = Diagnostics(directory: try temporaryFolder().appendingPathComponent("Logs"))
        log.record("first line")

        DispatchQueue.concurrentPerform(iterations: 300) { index in
            log.record("line \(index)")
        }

        let written = try lines(of: log)
        #expect(written.count == 301)
        #expect(Set(written.map { $0.split(separator: " ").last ?? "" }).count == 301)
    }

    // MARK: How long it stays

    @Test func eachDayHasItsOwnFile() throws {
        let folder = try temporaryFolder().appendingPathComponent("Logs")
        let log = Diagnostics(directory: folder)
        let day = try #require(ISO8601DateFormatter().date(from: "2026-11-07T08:00:00Z"))

        log.record("one", now: day)
        log.record("two", now: day.addingTimeInterval(86_400))

        #expect(try names(in: folder) == ["diagnostics-2026-11-07.log", "diagnostics-2026-11-08.log"])
    }

    @Test func aMonthIsForgotten() throws {
        let folder = try temporaryFolder()
        try plant("diagnostics-too-old.log", in: folder, daysOld: 31)
        try plant("diagnostics-recent.log", in: folder, daysOld: 29)

        let log = Diagnostics(directory: folder)
        log.record("today")

        let kept = try names(in: folder)
        #expect(!kept.contains("diagnostics-too-old.log"))
        #expect(kept.contains("diagnostics-recent.log"))
    }

    /// A build from before day files left these, and they have to age out like the rest.
    @Test func anOlderBuildsLogIsForgottenToo() throws {
        let folder = try temporaryFolder()
        try plant("diagnostics.log", in: folder, daysOld: 31)
        try plant("diagnostics.old.log", in: folder, daysOld: 40)

        Diagnostics(directory: folder).record("today")

        #expect(try names(in: folder).count == 1)
    }

    /// A Mac nothing is happening on still shouldn't hand over what it was meant to forget.
    @Test func anExportForgetsToo() throws {
        let folder = try temporaryFolder()
        let file = folder.appendingPathComponent("diagnostics-too-old.log")
        try Data("from long ago\n".utf8).write(to: file)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-31 * 86_400)], ofItemAtPath: file.path)

        let text = Diagnostics(directory: folder).exportedText(header: "CloudAccess")

        #expect(!text.contains("from long ago"))
    }

    @Test func onlyLogsAreEverRemoved() throws {
        let folder = try temporaryFolder()
        try plant("notes.txt", in: folder, daysOld: 400)

        Diagnostics(directory: folder).record("today")

        #expect(try names(in: folder).contains("notes.txt"))
    }

    // MARK: How big it gets

    @Test func aBusyDayCantGrowForever() throws {
        let folder = try temporaryFolder().appendingPathComponent("Logs")
        let log = Diagnostics(directory: folder)
        log.record(String(repeating: "a", count: 1_100_000))
        log.record(String(repeating: "b", count: 1_100_000))

        log.record("after both")

        #expect(try lines(of: log).count == 1)
        let text = log.exportedText(header: "CloudAccess")
        #expect(text.contains("bbbb"))
        #expect(!text.contains("aaaa"))
        #expect(try names(in: folder).count == 2)
    }

    /// A month of bad days, and the newest are what's worth keeping.
    @Test func theFolderStaysSmall() throws {
        let folder = try temporaryFolder()
        for day in 1...20 {
            try plant("diagnostics-day-\(day).log", in: folder, daysOld: Double(day), bytes: 1_000_000)
        }

        Diagnostics(directory: folder).record("today")

        let kept = try names(in: folder)
        let total = try kept.reduce(0) { sum, name in
            let attributes = try FileManager.default
                .attributesOfItem(atPath: folder.appendingPathComponent(name).path)
            return sum + ((attributes[.size] as? Int) ?? 0)
        }
        #expect(total <= 5_001_000)
        #expect(kept.contains("diagnostics-day-1.log"))
        #expect(!kept.contains("diagnostics-day-20.log"))
    }
}
