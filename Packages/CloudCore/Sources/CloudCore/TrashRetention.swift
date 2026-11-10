// Apache 2 license - developer@infinitecontext.com

import Foundation

/// How long a drive can keep what's deleted. The drive's policy on the server is what's in force,
/// so these are only the choices on offer, and the pace of checking that they're kept.
public enum TrashRetention {
    public struct Choice: Identifiable, Hashable, Sendable {
        /// The English, which is what the label is looked up by.
        let english: String
        public let seconds: Int

        public var id: Int { seconds }

        /// The time in the language shown, such as "7 days".
        public var label: String { Words.text(english) }
    }

    public static let choices = [
        Choice(english: "1 minute", seconds: 60),
        Choice(english: "1 hour", seconds: 3_600),
        Choice(english: "1 day", seconds: 86_400),
        Choice(english: "7 days", seconds: 7 * 86_400),
        Choice(english: "30 days", seconds: 30 * 86_400),
        Choice(english: "90 days", seconds: 90 * 86_400),
        Choice(english: "1 year", seconds: 365 * 86_400),
    ]

    /// What the engine uses when a drive has no policy.
    public static let defaultSeconds = 7 * 86_400

    private static let shortestPass: TimeInterval = 60
    private static let longestPass: TimeInterval = 86_400

    /// How often to look for what's past its time. A pass costs several requests, so it's only as
    /// often as the time asks for: once a day would make "1 minute" mean a day.
    /// - Parameter seconds: The drive's time, or `nil` before it's known.
    public static func passInterval(retention seconds: Int?) -> TimeInterval {
        guard let seconds else { return longestPass }
        return min(longestPass, max(shortestPass, TimeInterval(seconds) / 4))
    }
}
