// Apache 2 license - developer@infinitecontext.com

import Foundation

/// How a download is going, as the iPhone shows it, and how long each step took, as the log keeps it.
public struct DownloadProgress: Sendable, Equatable {
    /// The steps a person sees.
    public enum Step: String, Sendable, CaseIterable {
        case preparing
        case downloading
        case processing
    }

    public private(set) var step: Step = .preparing
    /// Bytes written on this device, after decrypting.
    public private(set) var bytes: Int64 = 0
    public let total: Int64?
    private var stepStarted: Date
    private var spent: [Step: TimeInterval] = [:]
    /// What came down, and in how long, across every try.
    private var downloadedBytes: Int64 = 0
    private var downloadSeconds: TimeInterval = 0

    /// A speed over less than this says more about when it was measured than about the network.
    private static let steadyAfter: TimeInterval = 2

    public init(total: Int64?, now: Date = Date()) {
        self.total = total
        stepStarted = now
    }

    /// A verified download's own stage, said the way a person reads it.
    public mutating func enter(_ stage: DownloadStage, now: Date = Date()) {
        finishStep(now: now)
        switch stage {
        case .checking:
            step = .preparing
        case .downloading:
            step = .downloading
            bytes = 0
        case .verifying:
            step = .processing
        }
        stepStarted = now
    }

    public mutating func received(_ bytes: Int64) {
        guard step == .downloading else { return }
        self.bytes = max(self.bytes, bytes)
    }

    /// How full the bar is, or nil when the size isn't known.
    public var fraction: Double? {
        switch step {
        case .preparing:
            return total == nil ? nil : 0
        case .processing:
            return 1
        case .downloading:
            guard let total, total > 0 else { return nil }
            return min(Double(bytes) / Double(total), 1)
        }
    }

    public func caption(now: Date = Date()) -> String {
        switch step {
        case .preparing:
            return "Preparing…"
        case .processing:
            return "Processing…"
        case .downloading:
            var parts: [String] = []
            if let fraction, let total {
                parts.append("Downloading \(Int(fraction * 100))%")
                parts.append("\(Self.size(bytes)) of \(Self.size(total))")
            } else {
                parts.append("Downloading \(Self.size(bytes))")
            }
            let elapsed = now.timeIntervalSince(stepStarted)
            if elapsed >= Self.steadyAfter, bytes > 0 {
                parts.append("\(Self.size(Int64(Double(bytes) / elapsed)))/s")
            }
            return parts.joined(separator: " · ")
        }
    }

    /// Where the time went, for the log: "preparing 1 s, downloading 40 s at 200 KB/s, processing 1 s".
    public func timings(now: Date = Date()) -> String {
        var copy = self
        copy.finishStep(now: now)
        return Step.allCases.compactMap { step in
            guard let seconds = copy.spent[step] else { return nil }
            var line = "\(step.rawValue) \(Int(seconds.rounded())) s"
            if step == .downloading, copy.downloadSeconds > 0 {
                line += " at \(Self.size(Int64(Double(copy.downloadedBytes) / copy.downloadSeconds)))/s"
            }
            return line
        }.joined(separator: ", ")
    }

    private mutating func finishStep(now: Date) {
        let seconds = max(now.timeIntervalSince(stepStarted), 0)
        spent[step, default: 0] += seconds
        if step == .downloading {
            downloadedBytes += bytes
            downloadSeconds += seconds
        }
        stepStarted = now
    }

    private static func size(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file))
    }
}
