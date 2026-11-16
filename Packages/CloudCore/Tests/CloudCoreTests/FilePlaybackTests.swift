// Apache 2 license - developer@infinitecontext.com

@testable import CloudCore
import Foundation
import Testing

@Suite struct FilePlaybackTests {
    private let drive = UUID()

    private func library() -> (OfflineLibrary, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (OfflineLibrary(directory: root), root)
    }

    private let film = RemotePath("/Films/Holiday.mp4")!
    private let other = RemotePath("/Films/Other.mp4")!
    private let chosen = FilePlayback(player: .vlc, aspectRatio: .standard)

    @Test func aFileWithNoChoiceUsesTheDefaults() {
        let (library, _) = library()
        #expect(library.playback(of: film, drive: drive) == FilePlayback())
        #expect(FilePlayback().player == .automatic)
        #expect(FilePlayback().aspectRatio == nil)
    }

    @Test func aFileRemembersItsPlayerAndRatio() {
        let (library, _) = library()
        library.setPlayback(chosen, for: film, drive: drive)
        #expect(library.playback(of: film, drive: drive) == chosen)
    }

    @Test func eachFileHasItsOwn() {
        let (library, _) = library()
        library.setPlayback(chosen, for: film, drive: drive)
        #expect(library.playback(of: other, drive: drive) == FilePlayback())
        #expect(library.playback(of: film, drive: UUID()) == FilePlayback())
    }

    @Test func backToTheDefaultsLeavesNothing() throws {
        let (library, root) = library()
        library.setPlayback(chosen, for: film, drive: drive)
        library.setPlayback(FilePlayback(), for: film, drive: drive)
        #expect(library.playback(of: film, drive: drive) == FilePlayback())
        let folder = root.appendingPathComponent(drive.uuidString).appendingPathComponent("playback")
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).isEmpty)
    }

    /// The choice is about the file, not the copy on the phone.
    @Test func removingTheDownloadKeepsTheChoice() throws {
        let (library, _) = library()
        let file = try library.temporaryFile(drive: drive)
        try Data("bytes".utf8).write(to: file)
        try library.keep(file, as: film, drive: drive)
        library.setPlayback(chosen, for: film, drive: drive)

        library.removeDownload(of: film, drive: drive)
        _ = library.removeExpired(mediaAfter: 0, otherAfter: 0)
        library.clearAbandoned()

        #expect(library.playback(of: film, drive: drive) == chosen)
    }

    @Test func removingTheDriveForgetsIt() {
        let (library, _) = library()
        library.setPlayback(chosen, for: film, drive: drive)
        library.remove(drive: drive)
        #expect(library.playback(of: film, drive: drive) == FilePlayback())
    }

    /// VLC reads a ratio as two whole numbers, so 1.85:1 is written 185:100.
    @Test func theRatiosAreWhatVLCReads() {
        #expect(AspectRatio.allCases.map(\.rawValue) == ["16:9", "4:3", "16:10", "185:100", "235:100", "1:1"])
        #expect(AspectRatio.allCases.map(\.shown) == ["16:9", "4:3", "16:10", "1.85:1", "2.35:1", "1:1"])
    }
}
