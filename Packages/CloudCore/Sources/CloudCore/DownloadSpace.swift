// Apache 2 license - developer@infinitecontext.com

import Foundation

/// How much space downloads may take on the iPhone. Sizes are decimal, as iOS shows storage.
public enum DownloadSpace {
    private static let gb: Int64 = 1_000_000_000

    /// The limits Settings offers.
    public static let choices: [Int64] = [5, 10, 15, 20, 25, 30].map { $0 * gb }

    /// The Mac's default cache size limit too.
    public static let defaultLimit: Int64 = 10 * gb

    /// The limit for a stored value. Nil is the default, and a value that isn't a choice, from an
    /// older build say, goes to the nearest one.
    public static func chosen(_ stored: Int?) -> Int64 {
        guard let stored else { return defaultLimit }
        let wanted = Int64(stored)
        return choices.min { abs($0 - wanted) < abs($1 - wanted) } ?? defaultLimit
    }
}

/// What downloads take on this iPhone now.
public struct DownloadUsage: Equatable, Sendable {
    /// Kept files, and the ones still arriving.
    public let bytes: Int64
    /// Kept files only: one still arriving isn't kept yet.
    public let files: Int

    public init(bytes: Int64, files: Int) {
        self.bytes = bytes
        self.files = files
    }

    /// The part of `limit` used, from 0. It can pass 1 while a download arrives.
    public func share(of limit: Int64) -> Double {
        limit > 0 ? Double(bytes) / Double(limit) : 0
    }
}
