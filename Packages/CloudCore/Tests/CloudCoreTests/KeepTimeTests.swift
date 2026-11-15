// Apache 2 license - developer@infinitecontext.com

@testable import CloudCore
import Foundation
import Testing

@Suite struct MediaFilesTests {
    @Test func filmsAndMusicAreMedia() {
        for name in ["Film.mkv", "clip.MP4", "holiday.Mov", "song.mp3", "album.FLAC", "a.b.webm"] {
            #expect(MediaFiles.isMedia(name), "\(name)")
        }
    }

    @Test func otherFilesAreNot() {
        for name in ["report.pdf", "notes.txt", "mp4", "photo.jpg", "archive.mkv.zip", "README"] {
            #expect(!MediaFiles.isMedia(name), "\(name)")
        }
    }

    @Test func onlyVideoIsVideo() {
        #expect(MediaFiles.isVideo("Film.MKV"))
        #expect(!MediaFiles.isVideo("song.mp3"))
        #expect(MediaFiles.kind(of: "song.mp3") == .audio)
    }

    /// The device's type database decides first; the lists only fill what it doesn't know.
    @Test func anExtensionNoDeviceDeclaresFallsBackToTheLists() {
        #expect(MediaFiles.kind(of: "track.alac") == .audio)
    }
}

/// Real file starts, as each container writes them.
@Suite struct MediaContainerTests {
    /// Letters or raw bytes, so a header reads as its format's documentation writes it.
    private enum Part: ExpressibleByStringLiteral, ExpressibleByArrayLiteral {
        case text(String)
        case raw([UInt8])

        init(stringLiteral value: String) { self = .text(value) }
        init(arrayLiteral elements: UInt8...) { self = .raw(elements) }

        var bytes: [UInt8] {
            switch self {
            case .text(let text): Array(text.utf8)
            case .raw(let raw): raw
            }
        }
    }

    private func bytes(_ parts: Part...) -> Data {
        Data(parts.flatMap(\.bytes))
    }

    /// 188-byte transport stream packets, each starting with the sync byte.
    private func transportStream(timestamped: Bool) -> Data {
        let packet = timestamped ? 192 : 188
        var data = Data(count: packet * 3)
        for index in 0..<3 {
            data[index * packet + (timestamped ? 4 : 0)] = 0x47
        }
        return data
    }

    @Test func everyContainerIsKnownByItsStart() {
        let cases: [(Data, MediaContainer)] = [
            (bytes([0, 0, 0, 0x20], "ftypisom", [0, 0, 2, 0]), .isoMedia),
            (bytes([0, 0, 0, 0x1C], "ftypM4A ", [0, 0, 0, 0]), .isoMedia),
            (bytes([0, 0, 0, 0x08], "wide", [0, 0, 0, 0]), .isoMedia),
            (bytes([0x1A, 0x45, 0xDF, 0xA3, 0x9F, 0x42, 0x86, 0x81]), .matroska),
            (bytes("RIFF", [0x24, 0, 0, 0], "AVI LIST"), .avi),
            (bytes("RIFF", [0x24, 0, 0, 0], "WAVEfmt "), .wav),
            (bytes("FORM", [0, 0, 0, 0x2E], "AIFFCOMM"), .aiff),
            (bytes("OggS", [0, 2, 0, 0]), .ogg),
            (bytes("fLaC", [0, 0, 0, 0x22]), .flac),
            (bytes("caff", [0, 1, 0, 0]), .caf),
            (bytes("FLV", [1, 5, 0, 0, 0, 9]), .flv),
            (bytes([0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11, 0xA6, 0xD9]), .asf),
            (bytes([0x00, 0x00, 0x01, 0xBA, 0x44, 0x00]), .mpegProgram),
            (transportStream(timestamped: false), .mpegTransport),
            (transportStream(timestamped: true), .mpegTransport),
            (bytes([0xFF, 0xFB, 0x90, 0x64]), .mp3),
            (bytes([0xFF, 0xF1, 0x50, 0x80]), .aac),
            (bytes("ID3", [3, 0, 0, 0, 0, 0, 4], "TAG!", [0xFF, 0xFB, 0x90, 0x64]), .mp3),
            (bytes("ID3", [4, 0, 0, 0, 0, 0, 4], "TAG!", [0xFF, 0xF1, 0x50, 0x80]), .aac),
        ]
        for (header, container) in cases {
            #expect(MediaContainer.identify(header) == container, "\(container)")
        }
    }

    @Test func otherFilesAreNoContainer() {
        let cases: [Data] = [
            Data(),
            bytes("PK", [3, 4, 20, 0]),
            bytes("%PDF-1.7"),
            bytes([0xFF, 0xD8, 0xFF, 0xE0, 0, 0x10], "JFIF"),
            bytes("RIFF", [0x24, 0, 0, 0], "WEBPVP8 "),
            bytes([0x89], "PNG", [0x0D, 0x0A, 0x1A, 0x0A]),
            bytes("Hello, this is a text file named film.mkv"),
            // One sync byte alone could be chance.
            bytes([0x47, 0x00, 0x00]),
        ]
        for header in cases {
            #expect(MediaContainer.identify(header) == nil, "\(Array(header.prefix(8)))")
        }
    }

    @Test func appleOpensWhatItKnowsAndVLCTheRest() {
        let apple: Set<MediaContainer> = [.isoMedia, .mp3, .aac, .wav, .aiff, .flac, .caf]
        for container in MediaContainer.allCases {
            #expect(container.isAppleNative == apple.contains(container), "\(container)")
        }
    }

    @Test func aMisnamedFileIsHandedOnUnderItsRealExtension() {
        #expect(MediaContainer.isoMedia.shownName(for: "Film.mkv") == "stream.mp4")
        #expect(MediaContainer.matroska.shownName(for: "Film.mp4") == "stream.mkv")
        #expect(MediaContainer.isoMedia.shownName(for: "Film.MOV") == "Film.MOV")
        #expect(MediaContainer.isoMedia.shownName(for: "Song.m4a") == "Song.m4a")
        #expect(MediaContainer.matroska.shownName(for: "Clip.webm") == "Clip.webm")
    }
}

@Suite struct KeepTimeTests {
    private let day = KeepTime.day

    @Test func theChoicesAreTheSevenAskedFor() {
        #expect(KeepTime.choices == [0.5, 1, 3, 7, 15, 30, 90].map { $0 * day })
        #expect(KeepTime.mediaDefault == 15 * day)
        #expect(KeepTime.otherDefault == 3 * day)
    }

    @Test func earlierChoicesMoveOntoTheList() {
        #expect(KeepTime.fromEarlierChoice(0) == 0.5 * day)
        #expect(KeepTime.fromEarlierChoice(3600) == 3 * day)
        #expect(KeepTime.fromEarlierChoice(86_400) == day)
        #expect(KeepTime.fromEarlierChoice(604_800) == 7 * day)
        #expect(KeepTime.fromEarlierChoice(nil) == 90 * day)
        #expect(KeepTime.fromEarlierChoice(30 * day) == 30 * day)
        // Never sooner than asked.
        #expect(KeepTime.fromEarlierChoice(2 * day) == 3 * day)
        #expect(KeepTime.fromEarlierChoice(400 * day) == 90 * day)
    }

    @Test func aChoiceReadsInWords() {
        #expect(KeepTime.shown(0.5 * day) == "Keep for 12 hours")
        #expect(KeepTime.shown(day) == "Keep for 1 day")
        #expect(KeepTime.shown(15 * day) == "Keep for 15 days")
    }

    @Test func aNewDriveKeepsMediaFor15DaysAndTheRestFor3() {
        let settings = DriveSettings()
        #expect(settings.removeMediaCopyAfter == 15 * day)
        #expect(settings.removeLocalCopyAfter == 3 * day)
    }

    private func decoded(_ json: String) throws -> DriveSettings {
        try JSONDecoder().decode(DriveSettings.self, from: Data(json.utf8))
    }

    @Test func aDriveSavedWithTheOldHourDefaultGetsTheNewDefaults() throws {
        let settings = try decoded(#"{"removeLocalCopyAfter": 3600, "mode": "safe"}"#)
        #expect(settings.removeLocalCopyAfter == 3 * day)
        #expect(settings.removeMediaCopyAfter == 15 * day)
    }

    @Test func aDriveSavedAsKeepGetsTheLongestTime() throws {
        let settings = try decoded(#"{"mode": "safe"}"#)
        #expect(settings.removeLocalCopyAfter == 90 * day)
        #expect(settings.removeMediaCopyAfter == 15 * day)
    }

    @Test func bothTimesSurviveSaving() throws {
        var settings = DriveSettings()
        settings.removeLocalCopyAfter = day
        settings.removeMediaCopyAfter = 90 * day
        let read = try JSONDecoder().decode(DriveSettings.self, from: JSONEncoder().encode(settings))
        #expect(read == settings)
    }
}

@Suite struct DownloadKeepTimeTests {
    private let drive = UUID()
    private let day = KeepTime.day
    private let start = Date(timeIntervalSince1970: 2_000_000_000)

    private func library() -> OfflineLibrary {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return OfflineLibrary(directory: root)
    }

    private func keep(_ name: String, in library: OfflineLibrary, at date: Date) throws -> RemotePath {
        let target = RemotePath("/\(name)")!
        let file = try library.temporaryFile(drive: drive)
        try Data("bytes".utf8).write(to: file)
        try library.keep(file, as: target, drive: drive, now: date)
        return target
    }

    private func sweep(_ library: OfflineLibrary, at date: Date, sparing: Set<URL> = []) -> Int {
        library.removeExpired(mediaAfter: 15 * day, otherAfter: 3 * day, sparing: sparing, now: date)
    }

    @Test func anOldDocumentGoesAndARecentFilmStays() throws {
        let library = library()
        let film = try keep("Film.mkv", in: library, at: start)
        let report = try keep("report.pdf", in: library, at: start)

        #expect(sweep(library, at: start.addingTimeInterval(4 * day)) == 1)

        #expect(library.download(of: film, drive: drive) != nil)
        #expect(library.download(of: report, drive: drive) == nil)
    }

    @Test func aFilmGoesAfterItsOwnTime() throws {
        let library = library()
        let film = try keep("Film.mp4", in: library, at: start)

        #expect(sweep(library, at: start.addingTimeInterval(10 * day)) == 0)
        #expect(sweep(library, at: start.addingTimeInterval(16 * day)) == 1)
        #expect(library.download(of: film, drive: drive) == nil)
    }

    @Test func usingAFileRestartsItsClock() throws {
        let library = library()
        let report = try keep("report.pdf", in: library, at: start)

        library.touch(report, drive: drive, now: start.addingTimeInterval(2 * day))

        #expect(sweep(library, at: start.addingTimeInterval(4 * day)) == 0)
        #expect(library.download(of: report, drive: drive) != nil)
    }

    @Test func theFilePlayingNowStays() throws {
        let library = library()
        let film = try keep("Film.mkv", in: library, at: start)
        let playing = try #require(library.download(of: film, drive: drive))

        #expect(sweep(library, at: start.addingTimeInterval(60 * day), sparing: [playing]) == 0)
        #expect(library.download(of: film, drive: drive) != nil)
    }

    @Test func aFileKeptBeforeKeepTimesSurvivesTheFirstPass() throws {
        let library = library()
        let report = try keep("report.pdf", in: library, at: start)
        // As an earlier build left it: no record of use.
        let folder = try #require(library.download(of: report, drive: drive)).deletingLastPathComponent()
        try FileManager.default.removeItem(at: folder.appendingPathComponent(".cm-used"))

        let later = start.addingTimeInterval(30 * day)
        #expect(sweep(library, at: later) == 0)
        #expect(library.download(of: report, drive: drive) != nil)
        // Its clock starts from that first pass.
        #expect(sweep(library, at: later.addingTimeInterval(4 * day)) == 1)
    }
}
