// Apache 2 license - developer@infinitecontext.com

import CloudCore
import Foundation
import Network

/// A tiny HTTP server inside the app that hands one file to a player, as it plays.
///
/// Both players already play an HTTP address that answers ranges, so one server feeds either.
/// It listens on 127.0.0.1 only, which iOS asks no permission for and no other device can reach,
/// and serves its one file at a random 128-bit path: anything else is answered 404. The bytes
/// come from the drive through the engine, so the server's password never reaches a player.
public actor LoopbackServer {
    /// Where a player reads the file. It ends in the file's own extension, which a player uses to
    /// tell the format.
    public private(set) var url: URL?

    private let reader: StreamReader
    private let path: String
    private let contentType: String
    private let onFailure: @Sendable (Error) -> Void
    private let queue = DispatchQueue(label: "LoopbackServer")
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]

    /// Starts serving. `onFailure` hears an error from the drive while sending, such as a lost
    /// connection to the server, so the app can say why the film stopped.
    public static func start(
        reader: StreamReader, fileName: String, onFailure: @escaping @Sendable (Error) -> Void = { _ in }
    ) async throws -> LoopbackServer {
        let server = LoopbackServer(reader: reader, fileName: fileName, onFailure: onFailure)
        try await server.listen()
        return server
    }

    private init(reader: StreamReader, fileName: String, onFailure: @escaping @Sendable (Error) -> Void) {
        self.reader = reader
        let ending = AddressEnding.of(fileName)
        path = "/\(Self.secret())/stream" + (ending.map { ".\($0)" } ?? "")
        contentType = StreamResponse.contentType(for: fileName)
        self.onFailure = onFailure
    }

    /// 128 random bits, from the system's secure generator.
    private static func secret() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &generator)) }.joined()
    }

    private func listen() async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        parameters.requiredInterfaceType = .loopback
        parameters.acceptLocalOnly = true
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let once = Once()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    once.run { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error):
                    once.run { continuation.resume(throwing: error) }
                case .cancelled:
                    once.run { continuation.resume(throwing: CancellationError()) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        url = URL(string: "http://127.0.0.1:\(port)\(path)")
    }

    /// Stops listening, ends every connection, and stops every read.
    public func stop() async {
        listener?.cancel()
        listener = nil
        for connection in connections.values {
            connection.cancel()
        }
        connections = [:]
        await reader.close()
    }

    private func accept(_ connection: NWConnection) {
        guard listener != nil else {
            connection.cancel()
            return
        }
        let id = UUID()
        connections[id] = connection
        connection.start(queue: queue)
        Task { await self.serve(connection, id: id) }
    }

    private func serve(_ connection: NWConnection, id: UUID) async {
        defer { connection.cancel() }
        var buffer = Data()
        do {
            while true {
                guard let next = try await nextRequest(on: connection, buffer: &buffer) else { break }
                guard let request = next.request else {
                    try await Self.send(StreamResponse.badRequest.head(closing: true), on: connection)
                    break
                }
                buffer = buffer.subdata(in: (buffer.startIndex + next.used)..<buffer.endIndex)
                guard request.path == path else {
                    try await Self.send(StreamResponse.notFound.head(closing: true), on: connection)
                    break
                }
                let response = StreamResponse.answer(to: request, size: reader.size, contentType: contentType)
                try await Self.send(response.head(closing: request.closesAfter), on: connection)
                if let body = response.body {
                    try await sendRange(body, for: id, on: connection)
                }
                if request.closesAfter { break }
            }
        } catch is CancellationError, RemoteError.cancelled {
            // The player closed, or the server is stopping.
        } catch is NWError {
            // The player dropped the connection, usually to read from somewhere else after a seek.
        } catch {
            // The drive failed: the film can't go on until it's back.
            onFailure(error)
        }
        connections[id] = nil
        await reader.drop(id)
    }

    /// The next request's head, waiting for more bytes until it has all arrived. Nil when the
    /// player has closed the connection.
    private func nextRequest(
        on connection: NWConnection, buffer: inout Data
    ) async throws -> (request: HTTPRequest?, used: Int)? {
        while true {
            if let found = HTTPRequest.first(in: buffer) { return found }
            if buffer.count > HTTPRequest.longestHead { return (nil, buffer.count) }
            guard let more = try await Self.receive(on: connection) else { return nil }
            buffer.append(more)
        }
    }

    /// Sends a range of the file, piece by piece, starting the next piece's read before sending
    /// this one. Each send waits for the player to take the bytes, so nothing races ahead of it.
    private func sendRange(_ range: ByteRange, for id: UUID, on connection: NWConnection) async throws {
        var offset = range.start
        while offset <= range.end {
            let index = offset / reader.pieceSize
            let piece = try await reader.piece(index, for: id)
            await reader.readAhead(index + 1, for: id)
            let pieceStart = index * reader.pieceSize
            let from = Int(offset - pieceStart)
            let to = Int(min(range.end, pieceStart + Int64(piece.count) - 1) - pieceStart)
            guard from <= to else { throw StreamReader.Failure.shortRead }
            try await Self.send(piece.subdata(in: from..<(to + 1)), on: connection)
            offset = pieceStart + Int64(to) + 1
        }
    }

    private static func receive(on connection: NWConnection) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if let error {
                    continuation.resume(throwing: error)
                } else if isComplete {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    private static func send(_ data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }
}

/// Runs something once, whichever thread asks first.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ body: () -> Void) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { body() }
    }
}

/// The file's extension as the player's address carries it: plain letters and digits only, so
/// nothing odd in a name can end up in the address.
enum AddressEnding {
    static func of(_ name: String) -> String? {
        let ending = (name as NSString).pathExtension.lowercased()
        guard !ending.isEmpty, ending.count <= 8, ending.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
        else { return nil }
        return ending
    }
}
