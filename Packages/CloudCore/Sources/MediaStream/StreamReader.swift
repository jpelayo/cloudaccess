// Apache 2 license - developer@infinitecontext.com

import CloudCore
import Foundation

/// Reads a file from a drive in pieces, as a player asks for it. The engine reads a range of a
/// file into a local file, so each piece goes through a temporary file that's deleted as soon as
/// its bytes are in hand.
///
/// It reads one piece ahead of what's being sent, and keeps the last few, so a player that jumps
/// back a little gets them at once. Each piece remembers which connections want it: when the last
/// one goes, as when a player seeks and drops a connection, its read is cancelled on the server.
public actor StreamReader {
    /// Reads `length` bytes from `offset` into a local file. On an encrypted drive the engine
    /// decrypts only the blocks it needs.
    public typealias Source = @Sendable (_ offset: Int64, _ length: Int64, _ destination: URL) async throws -> Void

    public enum Failure: Error, Equatable {
        /// The server sent fewer bytes than the file's size promised: it changed, or a read was cut.
        case shortRead
    }

    public let size: Int64
    public let pieceSize: Int64
    private let source: Source
    private let keptPieces: Int
    private let scratch: URL

    private struct Fetch {
        let id: UUID
        let task: Task<Data, Error>
        var wanted: Set<UUID>
    }

    private var fetches: [Int64: Fetch] = [:]
    private var kept: [Int64: Data] = [:]
    /// Kept pieces, least recently used first.
    private var keptOrder: [Int64] = []
    private var isClosed = false

    /// 4 MiB pieces, keeping the last 8: 32 MiB at most.
    public init(size: Int64, pieceSize: Int64 = 4 << 20, keptPieces: Int = 8, scratch: URL, source: @escaping Source) {
        self.size = size
        self.pieceSize = pieceSize
        self.keptPieces = keptPieces
        self.scratch = scratch
        self.source = source
    }

    /// Reads a file from a drive. The temporary files go in their own folder, removed by `close`.
    public init(backend: any RemoteBackend, path: RemotePath, size: Int64, scratch: URL) {
        self.init(size: size, scratch: scratch) { offset, length, destination in
            try await backend.read(path, offset: offset, length: length, to: destination)
        }
    }

    public var pieceCount: Int64 {
        size == 0 ? 0 : (size + pieceSize - 1) / pieceSize
    }

    private func pieceLength(of index: Int64) -> Int64 {
        min(pieceSize, size - index * pieceSize)
    }

    /// One piece, from what's kept, from a read already under way, or from a new read.
    public func piece(_ index: Int64, for connection: UUID) async throws -> Data {
        guard !isClosed, index >= 0, index < pieceCount else { throw CancellationError() }
        if let data = kept[index] {
            use(index)
            return data
        }
        return try await fetch(index, for: connection).value
    }

    /// The file's first bytes, enough to tell what container it really is. They come from the
    /// first piece, which a player reads first anyway, so it's kept for the player.
    public func header(length: Int = MediaContainer.headerLength) async throws -> Data {
        guard pieceCount > 0 else { return Data() }
        let asking = UUID()
        defer { drop(asking) }
        return Data(try await piece(0, for: asking).prefix(length))
    }

    /// Starts reading a piece before it's asked for, for the connection that will want it next.
    public func readAhead(_ index: Int64, for connection: UUID) {
        guard !isClosed, index >= 0, index < pieceCount, kept[index] == nil else { return }
        _ = fetch(index, for: connection)
    }

    /// A connection has ended. Reads no other connection wants are cancelled.
    public func drop(_ connection: UUID) {
        for (index, var fetch) in fetches {
            fetch.wanted.remove(connection)
            if fetch.wanted.isEmpty {
                fetch.task.cancel()
                fetches[index] = nil
            } else {
                fetches[index] = fetch
            }
        }
    }

    /// Stops every read, forgets every piece, and removes the temporary files.
    public func close() {
        isClosed = true
        for fetch in fetches.values {
            fetch.task.cancel()
        }
        fetches = [:]
        kept = [:]
        keptOrder = []
        try? FileManager.default.removeItem(at: scratch)
    }

    private func fetch(_ index: Int64, for connection: UUID) -> Task<Data, Error> {
        if var fetch = fetches[index] {
            fetch.wanted.insert(connection)
            fetches[index] = fetch
            return fetch.task
        }
        let id = UUID()
        let offset = index * pieceSize
        let length = pieceLength(of: index)
        let task = Task { [source, scratch] () async throws -> Data in
            do {
                let data = try await Self.load(offset: offset, length: length, scratch: scratch, source: source)
                await self.keep(data, at: index, from: id)
                return data
            } catch {
                await self.forget(index, from: id)
                throw error
            }
        }
        fetches[index] = Fetch(id: id, task: task, wanted: [connection])
        return task
    }

    private static func load(offset: Int64, length: Int64, scratch: URL, source: Source) async throws -> Data {
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let file = scratch.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try await source(offset, length, file)
        try Task.checkCancellation()
        let data = try Data(contentsOf: file)
        guard Int64(data.count) == length else { throw Failure.shortRead }
        return data
    }

    /// A finished read. A read that was cancelled and replaced by a newer one leaves no trace.
    private func keep(_ data: Data, at index: Int64, from id: UUID) {
        guard fetches[index]?.id == id else { return }
        fetches[index] = nil
        guard !isClosed else { return }
        kept[index] = data
        use(index)
        while keptOrder.count > keptPieces {
            kept[keptOrder.removeFirst()] = nil
        }
    }

    private func forget(_ index: Int64, from id: UUID) {
        if fetches[index]?.id == id {
            fetches[index] = nil
        }
    }

    private func use(_ index: Int64) {
        keptOrder.removeAll { $0 == index }
        keptOrder.append(index)
    }

    /// For tests: how many reads are under way.
    public var readsUnderWay: Int { fetches.count }
}
