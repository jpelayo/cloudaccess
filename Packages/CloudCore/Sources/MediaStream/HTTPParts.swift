// Apache 2 license - developer@infinitecontext.com

import CloudCore
import Foundation

/// The bytes a player asks for, from both ends inclusive, as HTTP counts them.
public struct ByteRange: Equatable, Sendable {
    public let start: Int64
    public let end: Int64

    public init(start: Int64, end: Int64) {
        self.start = start
        self.end = end
    }

    public var length: Int64 { end - start + 1 }

    public enum Request: Equatable, Sendable {
        /// No usable range: the whole file is sent.
        case whole
        case partial(ByteRange)
        /// A range that starts past the end, answered with 416.
        case unsatisfiable
    }

    /// Reads a `Range` header for a file of `size` bytes. As HTTP allows, a header that can't be
    /// read, or asks for several ranges, is ignored and the whole file is sent. Players ask for
    /// one range at a time.
    public static func request(_ header: String?, size: Int64) -> Request {
        guard let header else { return .whole }
        let text = header.trimmingCharacters(in: .whitespaces)
        guard text.lowercased().hasPrefix("bytes="), !text.contains(",") else { return .whole }
        let spec = text.dropFirst("bytes=".count).trimmingCharacters(in: .whitespaces)
        let parts = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return .whole }
        let first = parts[0].trimmingCharacters(in: .whitespaces)
        let last = parts[1].trimmingCharacters(in: .whitespaces)

        if first.isEmpty {
            // The last n bytes.
            guard let count = Int64(last), count >= 0 else { return .whole }
            guard count > 0, size > 0 else { return .unsatisfiable }
            return .partial(ByteRange(start: max(0, size - count), end: size - 1))
        }
        guard let start = Int64(first), start >= 0 else { return .whole }
        guard start < size else { return .unsatisfiable }
        if last.isEmpty {
            return .partial(ByteRange(start: start, end: size - 1))
        }
        guard let end = Int64(last), end >= start else { return .whole }
        return .partial(ByteRange(start: start, end: min(end, size - 1)))
    }
}

/// One request from a player: its method, path and headers. A player sends nothing in a body.
public struct HTTPRequest: Equatable, Sendable {
    public let method: String
    public let path: String
    /// Header names in lower case.
    public let headers: [String: String]

    /// A request's head is never this long, so anything longer is refused rather than buffered.
    public static let longestHead = 16 * 1024

    public var closesAfter: Bool {
        headers["connection"]?.lowercased() == "close"
    }

    /// The first request in `data`, and how many bytes it took, or nil if its head hasn't all
    /// arrived yet.
    public static func first(in data: Data) -> (request: HTTPRequest?, used: Int)? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let used = end.upperBound - data.startIndex
        let head = String(decoding: data[data.startIndex..<end.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count == 3 else { return (nil, used) }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return (HTTPRequest(method: String(requestLine[0]), path: String(requestLine[1]), headers: headers), used)
    }
}

/// What the loopback server answers: a status, headers, and the bytes of the file to send.
public struct StreamResponse: Equatable, Sendable {
    public let status: Int
    /// In the order they're sent.
    public let headers: [String]
    /// The bytes of the file that follow the head, or nil for none.
    public let body: ByteRange?

    public static func answer(to request: HTTPRequest, size: Int64, contentType: String) -> StreamResponse {
        let isHead = request.method == "HEAD"
        guard request.method == "GET" || isHead else {
            return StreamResponse(status: 405, headers: ["Allow: GET, HEAD", "Content-Length: 0"], body: nil)
        }
        let common = ["Content-Type: \(contentType)", "Accept-Ranges: bytes", "Cache-Control: no-store"]
        switch ByteRange.request(request.headers["range"], size: size) {
        case .whole:
            let range = size > 0 ? ByteRange(start: 0, end: size - 1) : nil
            return StreamResponse(
                status: 200, headers: common + ["Content-Length: \(size)"], body: isHead ? nil : range)
        case .partial(let range):
            return StreamResponse(
                status: 206,
                headers: common + ["Content-Range: bytes \(range.start)-\(range.end)/\(size)",
                                   "Content-Length: \(range.length)"],
                body: isHead ? nil : range)
        case .unsatisfiable:
            return StreamResponse(
                status: 416, headers: ["Content-Range: bytes */\(size)", "Content-Length: 0"], body: nil)
        }
    }

    /// For any path but the one secret path.
    public static let notFound = StreamResponse(status: 404, headers: ["Content-Length: 0"], body: nil)
    /// For a head too long or that can't be read.
    public static let badRequest = StreamResponse(status: 400, headers: ["Content-Length: 0"], body: nil)

    public func head(closing: Bool) -> Data {
        let reason = switch status {
        case 200: "OK"
        case 206: "Partial Content"
        case 400: "Bad Request"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 416: "Range Not Satisfiable"
        default: "Error"
        }
        let lines = ["HTTP/1.1 \(status) \(reason)"] + headers + (closing ? ["Connection: close"] : [])
        return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }

    /// The media type for a file's extension, so a player knows what it's reading.
    public static func contentType(for name: String) -> String {
        switch MediaFiles.fileExtension(of: name) {
        case "mp4": "video/mp4"
        case "m4v": "video/x-m4v"
        case "mov": "video/quicktime"
        case "mkv": "video/x-matroska"
        case "webm": "video/webm"
        case "avi", "divx": "video/x-msvideo"
        case "wmv": "video/x-ms-wmv"
        case "flv": "video/x-flv"
        case "ts", "m2ts", "mts": "video/mp2t"
        case "mpg", "mpeg", "vob": "video/mpeg"
        case "ogv": "video/ogg"
        case "3gp": "video/3gpp"
        default: "application/octet-stream"
        }
    }
}
