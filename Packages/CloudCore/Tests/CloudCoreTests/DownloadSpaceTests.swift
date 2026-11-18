// Apache 2 license - developer@infinitecontext.com

@testable import CloudCore
import Foundation
import Testing

@Suite struct DownloadSpaceTests {
    private let drive = UUID()
    private let start = Date(timeIntervalSince1970: 2_000_000_000)
    private let gb: Int64 = 1_000_000_000

    private func library() -> (OfflineLibrary, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (OfflineLibrary(directory: root), root)
    }

    /// Keeps a file of `bytes` bytes, last used `minutes` after the start.
    @discardableResult
    private func keep(_ name: String, bytes: Int, usedAt minutes: Double = 0, in library: OfflineLibrary) throws
        -> RemotePath {
        let target = RemotePath("/\(name)")!
        let file = try library.temporaryFile(drive: drive)
        try Data(count: bytes).write(to: file)
        try library.keep(file, as: target, drive: drive, version: "v1", now: start.addingTimeInterval(minutes * 60))
        return target
    }

    private func isKept(_ path: RemotePath, in library: OfflineLibrary) -> Bool {
        library.download(of: path, drive: drive) != nil
    }

    // MARK: The limit

    @Test func theChoicesAreFiveToThirtyGB() {
        #expect(DownloadSpace.choices == [5, 10, 15, 20, 25, 30].map { $0 * gb })
    }

    @Test func tenGBIsTheDefault() {
        #expect(DownloadSpace.defaultLimit == 10 * gb)
        #expect(DownloadSpace.chosen(nil) == 10 * gb)
    }

    @Test func anUnknownLimitGoesToTheNearestChoice() {
        #expect(DownloadSpace.chosen(Int(20 * gb)) == 20 * gb)
        #expect(DownloadSpace.chosen(Int(12 * gb)) == 10 * gb)
        #expect(DownloadSpace.chosen(Int(gb)) == 5 * gb)
        #expect(DownloadSpace.chosen(Int(100 * gb)) == 30 * gb)
    }

    @Test func theShareIsUsedOverTheLimit() {
        let usage = DownloadUsage(bytes: 25, files: 1)
        #expect(usage.share(of: 100) == 0.25)
        #expect(usage.share(of: 0) == 0)
    }

    // MARK: What counts

    @Test func usageCountsKeptFilesAndOnesArriving() throws {
        let (library, _) = library()
        try keep("a.pdf", bytes: 100, in: library)
        try keep("b.mkv", bytes: 300, in: library)
        let arriving = try library.temporaryFile(drive: drive)
        try Data(count: 50).write(to: arriving)

        #expect(library.usage() == DownloadUsage(bytes: 450, files: 2))
    }

    /// Records sit beside every kept file, and aren't the file.
    @Test func usageSkipsRecords() throws {
        let (library, _) = library()
        let path = try keep("a.pdf", bytes: 100, in: library)
        library.setOwnKeepTime(KeepTime.day, for: path, drive: drive)
        #expect(library.usage() == DownloadUsage(bytes: 100, files: 1))
    }

    @Test func anEmptyLibraryUsesNothing() {
        #expect(library().0.usage() == DownloadUsage(bytes: 0, files: 0))
    }

    // MARK: Over the limit

    @Test func overTheLimitOtherFilesGoBeforeMedia() throws {
        let (library, _) = library()
        let film = try keep("old.mkv", bytes: 100, usedAt: 0, in: library)
        let report = try keep("new.pdf", bytes: 100, usedAt: 10, in: library)

        #expect(library.removeOverLimit(150, sparing: []) == 1)

        #expect(isKept(film, in: library))
        #expect(!isKept(report, in: library))
    }

    @Test func overTheLimitTheOldestGoesFirst() throws {
        let (library, _) = library()
        let older = try keep("older.pdf", bytes: 100, usedAt: 0, in: library)
        let newer = try keep("newer.pdf", bytes: 100, usedAt: 10, in: library)
        let oldFilm = try keep("old.mkv", bytes: 100, usedAt: 0, in: library)
        let newFilm = try keep("new.mkv", bytes: 100, usedAt: 10, in: library)

        #expect(library.removeOverLimit(150, sparing: []) == 3)

        #expect(!isKept(older, in: library))
        #expect(!isKept(newer, in: library))
        #expect(!isKept(oldFilm, in: library))
        #expect(isKept(newFilm, in: library))
    }

    @Test func theSparedFilesStayOverTheLimit() throws {
        let (library, _) = library()
        let playing = try keep("playing.pdf", bytes: 100, usedAt: 0, in: library)
        let other = try keep("other.pdf", bytes: 100, usedAt: 10, in: library)
        let spared = try #require(library.download(of: playing, drive: drive))

        #expect(library.removeOverLimit(150, sparing: [spared]) == 1)

        #expect(isKept(playing, in: library))
        #expect(!isKept(other, in: library))
    }

    @Test func underTheLimitNothingGoes() throws {
        let (library, _) = library()
        try keep("a.pdf", bytes: 100, in: library)
        try keep("b.mkv", bytes: 100, in: library)
        #expect(library.removeOverLimit(200, sparing: []) == 0)
        #expect(library.usage().files == 2)
    }

    // MARK: Remove all

    @Test func removeAllLeavesListingsAndChoices() throws {
        let (library, _) = library()
        let path = try keep("film.mp4", bytes: 100, in: library)
        try keep("b.pdf", bytes: 100, in: library)
        let folder = RemotePath("/")!
        try library.save(listing: [], of: folder, drive: drive)
        let chosen = FilePlayback(player: .vlc, aspectRatio: .wide)
        library.setPlayback(chosen, for: path, drive: drive)

        #expect(library.removeAllDownloads(sparing: []) == 2)

        #expect(library.usage() == DownloadUsage(bytes: 0, files: 0))
        #expect(library.hasListing(of: folder, drive: drive))
        #expect(library.playback(of: path, drive: drive) == chosen)
    }

    @Test func removeAllLeavesADownloadArriving() throws {
        let (library, _) = library()
        try keep("a.pdf", bytes: 100, in: library)
        let arriving = try library.temporaryFile(drive: drive)
        try Data(count: 50).write(to: arriving)

        library.removeAllDownloads(sparing: [])

        #expect(FileManager.default.fileExists(atPath: arriving.path))
        #expect(library.usage() == DownloadUsage(bytes: 50, files: 0))
    }

    @Test func removeAllKeepsTheFilePlaying() throws {
        let (library, _) = library()
        let playing = try keep("playing.mkv", bytes: 100, in: library)
        try keep("other.pdf", bytes: 100, in: library)
        let spared = try #require(library.download(of: playing, drive: drive))

        #expect(library.removeAllDownloads(sparing: [spared]) == 1)
        #expect(isKept(playing, in: library))
    }
}
