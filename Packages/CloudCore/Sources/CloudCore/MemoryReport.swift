// Apache 2 license - developer@infinitecontext.com

import Foundation

/// How much memory the iPhone's Files extension uses. iOS stops that extension at about 20 MB,
/// and this is how anyone can see how close it gets. It holds no names, and it never leaves the
/// phone unless a person sends it.
public struct MemoryReport: Codable, Equatable, Sendable {
    /// What the extension had just done, such as "download".
    public var event: String
    public var date: Date
    /// What it used then, in bytes, as iOS counts it.
    public var now: UInt64
    /// The most this run of the extension had used.
    public var peak: UInt64
    /// The most any run has used since the report was first written.
    public var highest: UInt64
    /// What iOS said was left before it would stop the extension. Added to what's in use, that's
    /// the real limit.
    public var available: UInt64?
    /// Threads in the process. Each one costs memory of its own.
    public var threads: Int?
    /// Drives this process was serving. iOS may put several in one process, and the limit is
    /// for all of them together.
    public var drives: Int?

    public init(
        event: String, date: Date, now: UInt64, peak: UInt64, highest: UInt64,
        available: UInt64? = nil, threads: Int? = nil, drives: Int? = nil
    ) {
        self.event = event
        self.date = date
        self.now = now
        self.peak = peak
        self.highest = highest
        self.available = available
        self.threads = threads
        self.drives = drives
    }

    /// The limit iOS applies, worked out from what was in use and what was left.
    public var limit: UInt64? {
        available.map { now + $0 }
    }

    public static func read(from url: URL) -> MemoryReport? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(MemoryReport.self, from: data)
    }

    /// Saves a measurement, keeping the highest seen across runs.
    /// - Returns: The report, and whether it's a new highest.
    @discardableResult
    public static func record(
        event: String, now: UInt64, peak: UInt64, available: UInt64?, threads: Int?, drives: Int?,
        at url: URL, date: Date = Date()
    ) -> (report: MemoryReport, isNewHighest: Bool) {
        let earlier = read(from: url)?.highest ?? 0
        let highest = max(earlier, peak, now)
        let report = MemoryReport(
            event: event, date: date, now: now, peak: peak, highest: highest,
            available: available, threads: threads, drives: drives)
        try? JSONEncoder().encode(report).write(to: url, options: .atomic)
        return (report, highest > earlier)
    }

    /// Megabytes as iOS's limit is written, with one decimal.
    public static func megabytes(_ bytes: UInt64) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }

    /// One line for the diagnostics log, with numbers only.
    public var summary: String {
        var parts = ["peak \(Self.megabytes(peak)) after \(event)"]
        if let limit { parts.append("limit \(Self.megabytes(limit))") }
        if let threads { parts.append("\(threads) threads") }
        if let drives { parts.append("\(drives) drives") }
        return "Files extension memory: " + parts.joined(separator: ", ")
    }
}
