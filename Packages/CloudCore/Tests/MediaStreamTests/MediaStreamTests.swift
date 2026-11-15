// Apache 2 license - developer@infinitecontext.com

import CloudCore
import FakeRemote
import Foundation
import Network
import Testing

@testable import MediaStream

@Suite struct ByteRangeTests {
    @Test func everyFormOfRangeIsRead() {
        #expect(ByteRange.request("bytes=0-1", size: 100) == .partial(ByteRange(start: 0, end: 1)))
        #expect(ByteRange.request("bytes=40-", size: 100) == .partial(ByteRange(start: 40, end: 99)))
        #expect(ByteRange.request("bytes=-10", size: 100) == .partial(ByteRange(start: 90, end: 99)))
        #expect(ByteRange.request("Bytes = 5-9", size: 100) == .partial(ByteRange(start: 5, end: 9)))
    }

    @Test func anEndPastTheFileIsClampedToIt() {
        #expect(ByteRange.request("bytes=90-500", size: 100) == .partial(ByteRange(start: 90, end: 99)))
        #expect(ByteRange.request("bytes=-500", size: 100) == .partial(ByteRange(start: 0, end: 99)))
    }

    @Test func aStartPastTheEndIsRefused() {
        #expect(ByteRange.request("bytes=100-", size: 100) == .unsatisfiable)
        #expect(ByteRange.request("bytes=200-300", size: 100) == .unsatisfiable)
        #expect(ByteRange.request("bytes=-0", size: 100) == .unsatisfiable)
        #expect(ByteRange.request("bytes=0-", size: 0) == .unsatisfiable)
    }

    /// HTTP lets a server ignore a range it can't use, and send the whole file.
    @Test func aRangeThatCantBeReadIsIgnored() {
        for header in [nil, "", "items=0-1", "bytes=a-b", "bytes=9-3", "bytes=0-1,5-6", "bytes=--1"] {
            #expect(ByteRange.request(header, size: 100) == .whole, "\(header ?? "nil")")
        }
    }
}

@Suite struct StreamResponseTests {
    private func request(_ method: String = "GET", range: String? = nil) -> HTTPRequest {
        HTTPRequest(method: method, path: "/x", headers: range.map { ["range": $0] } ?? [:])
    }

    @Test func noRangeSendsTheWholeFile() {
        let response = StreamResponse.answer(to: request(), size: 100, contentType: "video/mp4")
        #expect(response.status == 200)
        #expect(response.headers.contains("Content-Length: 100"))
        #expect(response.headers.contains("Accept-Ranges: bytes"))
        #expect(response.body == ByteRange(start: 0, end: 99))
    }

    @Test func aRangeSendsPartOfIt() {
        let response = StreamResponse.answer(to: request(range: "bytes=10-19"), size: 100, contentType: "video/mp4")
        #expect(response.status == 206)
        #expect(response.headers.contains("Content-Range: bytes 10-19/100"))
        #expect(response.headers.contains("Content-Length: 10"))
        #expect(response.body == ByteRange(start: 10, end: 19))
    }

    @Test func headSendsTheHeadersAndNoBytes() {
        let response = StreamResponse.answer(to: request("HEAD", range: "bytes=10-19"), size: 100, contentType: "video/mp4")
        #expect(response.status == 206)
        #expect(response.headers.contains("Content-Length: 10"))
        #expect(response.body == nil)
    }

    @Test func aRangePastTheEndIs416() {
        let response = StreamResponse.answer(to: request(range: "bytes=500-"), size: 100, contentType: "video/mp4")
        #expect(response.status == 416)
        #expect(response.headers.contains("Content-Range: bytes */100"))
        #expect(response.body == nil)
    }

    @Test func onlyReadingIsAllowed() {
        let response = StreamResponse.answer(to: request("PUT"), size: 100, contentType: "video/mp4")
        #expect(response.status == 405)
        #expect(response.body == nil)
    }

    @Test func eachFormatHasItsType() {
        #expect(StreamResponse.contentType(for: "a.mp4") == "video/mp4")
        #expect(StreamResponse.contentType(for: "a.MOV") == "video/quicktime")
        #expect(StreamResponse.contentType(for: "a.mkv") == "video/x-matroska")
        #expect(StreamResponse.contentType(for: "a.xyz") == "application/octet-stream")
    }

    @Test func aRequestHeadIsReadOnceItHasAllArrived() throws {
        let text = "GET /abc/stream.mp4 HTTP/1.1\r\nHost: 127.0.0.1\r\nRange: bytes=0-1\r\n\r\nGET"
        let found = try #require(HTTPRequest.first(in: Data(text.utf8)))
        let request = try #require(found.request)
        #expect(request.method == "GET")
        #expect(request.path == "/abc/stream.mp4")
        #expect(request.headers["range"] == "bytes=0-1")
        #expect(found.used == text.utf8.count - 3)
        #expect(HTTPRequest.first(in: Data("GET / HTTP/1.1\r\nHost: x\r\n".utf8)) == nil)
    }
}

@Suite struct PlayerChoiceTests {
    @Test func filmsAndSoundOfferToPlay() {
        for name in ["a.mp4", "b.M4V", "c.mov", "d.mkv", "e.AVI", "f.webm", "song.mp3", "album.flac"] {
            #expect(PlayerChoice.isPlayable(name), "\(name)")
        }
    }

    @Test func otherFilesDont() {
        for name in ["a.pdf", "README", "b.jpg", "archive.zip"] {
            #expect(!PlayerChoice.isPlayable(name), "\(name)")
        }
    }

    /// What the file really is decides, not its name.
    @Test func theContainerPicksThePlayer() {
        #expect(PlayerChoice.player(for: .isoMedia) == .apple)
        #expect(PlayerChoice.player(for: .mp3) == .apple)
        #expect(PlayerChoice.player(for: .matroska) == .vlc)
        #expect(PlayerChoice.player(for: .asf) == .vlc)
    }

    @Test func eachRowStateHasItsButtons() {
        #expect(PlayButtons.shown(isPlayable: true, isDownloaded: false, isDownloading: false) == [.playNow, .downloadAndPlay])
        #expect(PlayButtons.shown(isPlayable: true, isDownloaded: false, isDownloading: true) == [.playNow])
        #expect(PlayButtons.shown(isPlayable: true, isDownloaded: true, isDownloading: false) == [.play])
        #expect(PlayButtons.shown(isPlayable: false, isDownloaded: true, isDownloading: false).isEmpty)
    }

    /// Streaming and the copy on the phone must look different at a glance.
    @Test func streamingAndTheCopyHaveDifferentSymbols() {
        let symbols = [PlayButton.playNow, .downloadAndPlay, .play].map(\.systemImage)
        #expect(Set(symbols).count == 3)
        #expect(PlayButton.playNow.systemImage == "play.circle")
        #expect(PlayButton.play.systemImage == "play.circle.fill")
    }
}

/// A file of known bytes on a fake drive, read through a reader with small pieces.
private struct Film {
    let remote = FakeRemote()
    let path = RemotePath("/Film.mp4")!
    let bytes: Data
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

    init(size: Int = 100) async {
        bytes = Data((0..<size).map { UInt8($0 % 251) })
        await remote.put(path, content: bytes)
    }

    func reader(pieceSize: Int64 = 10, keptPieces: Int = 3) -> StreamReader {
        let remote = remote
        let path = path
        return StreamReader(size: Int64(bytes.count), pieceSize: pieceSize, keptPieces: keptPieces, scratch: scratch) {
            offset, length, destination in
            try await remote.read(path, offset: offset, length: length, to: destination)
        }
    }
}

@Suite struct StreamReaderTests {
    @Test func eachPieceHoldsExactlyItsBytes() async throws {
        let film = await Film(size: 95)
        let reader = film.reader()
        let connection = UUID()

        #expect(await reader.pieceCount == 10)
        #expect(try await reader.piece(0, for: connection) == film.bytes.subdata(in: 0..<10))
        #expect(try await reader.piece(9, for: connection) == film.bytes.subdata(in: 90..<95))
    }

    @Test func aKeptPieceIsntReadAgain() async throws {
        let film = await Film()
        let reader = film.reader()
        let connection = UUID()

        _ = try await reader.piece(2, for: connection)
        _ = try await reader.piece(2, for: connection)

        #expect(await film.remote.readOffsets == [20])
    }

    @Test func readingAheadAsksForTheNextPiece() async throws {
        let film = await Film()
        let reader = film.reader()
        let connection = UUID()

        await reader.readAhead(1, for: connection)
        _ = try await reader.piece(1, for: connection)

        #expect(await film.remote.readOffsets == [10])
    }

    @Test func onlyTheLastFewPiecesAreKept() async throws {
        let film = await Film()
        let reader = film.reader(keptPieces: 2)
        let connection = UUID()

        for index in Int64(0)..<3 {
            _ = try await reader.piece(index, for: connection)
        }
        _ = try await reader.piece(0, for: connection)

        #expect(await film.remote.readOffsets == [0, 10, 20, 0])
    }

    @Test func aDroppedConnectionStopsItsReads() async throws {
        let film = await Film()
        await film.remote.slowReads(by: .seconds(30))
        let reader = film.reader()
        let connection = UUID()

        await reader.readAhead(4, for: connection)
        for _ in 0..<200 where await film.remote.readOffsets.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        await reader.drop(connection)
        for _ in 0..<200 where await film.remote.cancelledReads == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }

        #expect(await film.remote.cancelledReads == 1)
        #expect(await reader.readsUnderWay == 0)
    }

    @Test func aReadAnotherConnectionWantsCarriesOn() async throws {
        let film = await Film()
        let reader = film.reader()
        let leaving = UUID()
        let staying = UUID()

        await reader.readAhead(3, for: leaving)
        await reader.readAhead(3, for: staying)
        await reader.drop(leaving)

        #expect(try await reader.piece(3, for: staying) == film.bytes.subdata(in: 30..<40))
        #expect(await film.remote.cancelledReads == 0)
    }

    @Test func aFailureFromTheDriveReachesTheReader() async throws {
        let film = await Film()
        await film.remote.fail(with: .unreachable("The connection was lost"))
        let reader = film.reader()

        await #expect(throws: RemoteError.self) {
            try await reader.piece(0, for: UUID())
        }
    }

    @Test func aShortReadIsAFailure() async throws {
        let film = await Film(size: 100)
        // The reader believes the file is longer than it is, as when it shrank on the server.
        let remote = film.remote
        let path = film.path
        let reader = StreamReader(size: 120, pieceSize: 10, scratch: film.scratch) { offset, length, destination in
            try await remote.read(path, offset: offset, length: length, to: destination)
        }

        await #expect(throws: StreamReader.Failure.shortRead) {
            try await reader.piece(11, for: UUID())
        }
    }

    @Test func theHeaderIsTheFirstPieceAndStaysForThePlayer() async throws {
        let film = await Film(size: 95)
        let reader = film.reader()

        #expect(try await reader.header(length: 4) == film.bytes.subdata(in: 0..<4))
        _ = try await reader.piece(0, for: UUID())

        #expect(await film.remote.readOffsets == [0])
    }

    @Test func closingRemovesTheTemporaryFiles() async throws {
        let film = await Film()
        let reader = film.reader()
        _ = try await reader.piece(0, for: UUID())
        #expect(FileManager.default.fileExists(atPath: film.scratch.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: film.scratch.path).isEmpty)

        await reader.close()

        #expect(!FileManager.default.fileExists(atPath: film.scratch.path))
    }
}

@Suite struct LoopbackServerTests {
    /// Sends one raw request, as a player would, and reads the answer until the server closes.
    private func fetch(_ url: URL, path: String, range: String?) async throws -> (head: String, body: Data) {
        let port = try #require(url.port.flatMap { NWEndpoint.Port(rawValue: UInt16($0)) })
        let connection = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        let queue = DispatchQueue(label: "test client")
        connection.start(queue: queue)
        defer { connection.cancel() }
        var request = "GET \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n"
        if let range { request += "Range: \(range)\r\n" }
        request += "\r\n"
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: Data(request.utf8), completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
        var answer = Data()
        while true {
            let (data, done): (Data?, Bool) = try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                    if let error, data == nil { continuation.resume(throwing: error) } else {
                        continuation.resume(returning: (data, isComplete))
                    }
                }
            }
            if let data { answer.append(data) }
            if done { break }
        }
        let split = try #require(answer.range(of: Data("\r\n\r\n".utf8)))
        return (String(decoding: answer[..<split.lowerBound], as: UTF8.self), answer[split.upperBound...])
    }

    @Test func aRangeComesBackAsThoseBytes() async throws {
        let film = await Film(size: 100)
        let server = try await LoopbackServer.start(reader: film.reader(), fileName: "Film.mp4")
        let url = try #require(await server.url)

        let answer = try await fetch(url, path: url.path, range: "bytes=25-54")

        #expect(answer.head.hasPrefix("HTTP/1.1 206"))
        #expect(answer.head.contains("Content-Range: bytes 25-54/100"))
        #expect(answer.body == film.bytes.subdata(in: 25..<55))
        await server.stop()
    }

    @Test func theWholeFileComesBackWithNoRange() async throws {
        let film = await Film(size: 95)
        let server = try await LoopbackServer.start(reader: film.reader(), fileName: "Film.mkv")
        let url = try #require(await server.url)

        let answer = try await fetch(url, path: url.path, range: nil)

        #expect(answer.head.hasPrefix("HTTP/1.1 200"))
        #expect(answer.body == film.bytes)
        await server.stop()
    }

    @Test func anyOtherPathIsNotFound() async throws {
        let film = await Film()
        let server = try await LoopbackServer.start(reader: film.reader(), fileName: "Film.mp4")
        let url = try #require(await server.url)

        let answer = try await fetch(url, path: "/stream.mp4", range: nil)

        #expect(answer.head.hasPrefix("HTTP/1.1 404"))
        #expect(answer.body.isEmpty)
        #expect(await film.remote.readOffsets.isEmpty)
        await server.stop()
    }

    @Test func itListensOnThisDeviceOnlyAtASecretPath() async throws {
        let film = await Film()
        let server = try await LoopbackServer.start(reader: film.reader(), fileName: "Film.mp4")
        let url = try #require(await server.url)

        #expect(url.host == "127.0.0.1")
        // A 32-letter secret, then the file's own extension.
        let parts = url.path.split(separator: "/")
        #expect(parts.count == 2)
        #expect(parts[0].count == 32)
        #expect(parts[1] == "stream.mp4")
        await server.stop()
    }

    @Test func aDriveFailureIsReported() async throws {
        let film = await Film()
        await film.remote.fail(with: .unreachable("The connection was lost"))
        let heard = Heard()
        let server = try await LoopbackServer.start(reader: film.reader(), fileName: "Film.mp4") { error in
            heard.note(error)
        }
        let url = try #require(await server.url)

        _ = try? await fetch(url, path: url.path, range: "bytes=0-9")

        #expect(heard.errors.count == 1)
        await server.stop()
    }
}

/// What a callback heard, from whichever thread.
private final class Heard: @unchecked Sendable {
    private let lock = NSLock()
    private var heard: [Error] = []

    func note(_ error: Error) {
        lock.lock()
        heard.append(error)
        lock.unlock()
    }

    var errors: [Error] {
        lock.lock()
        defer { lock.unlock() }
        return heard
    }
}
