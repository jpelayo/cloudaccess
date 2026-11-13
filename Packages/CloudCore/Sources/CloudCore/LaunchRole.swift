// Apache 2 license - developer@infinitecontext.com

import Foundation

/// What this copy of the Mac app should do at launch. With launch at login on, the copy that
/// runs should be the launch agent's, because that's the one macOS brings back if it ends.
public enum LaunchRole: Equatable, Sendable {
    /// Run normally.
    case run
    /// Opened by hand with the agent on: start the agent's copy, then leave.
    case handOver
    /// Another copy is running and is due to end: wait for it, then decide.
    case standBy(pid: Int32)
    /// Opened by hand while another copy runs: show that one and leave. The exit is
    /// successful, so launchd never restarts this copy.
    case leave(pid: Int32)

    public static func decide(
        launchedByAgent: Bool, agentEnabled: Bool, otherCopy: Int32?
    ) -> LaunchRole {
        if let otherCopy {
            return launchedByAgent ? .standBy(pid: otherCopy) : .leave(pid: otherCopy)
        }
        return !launchedByAgent && agentEnabled ? .handOver : .run
    }
}

/// Why a copy ended on purpose, so a copy standing by knows whether to take over. A crash
/// leaves no note, and the copy standing by runs.
public struct ExitNote: Codable, Equatable, Sendable {
    public enum Reason: String, Codable, Sendable {
        case quit
    }

    public var pid: Int32
    public var reason: Reason
    /// When it quit. A note from an older build has none.
    public var date: Date?

    public init(pid: Int32, reason: Reason, date: Date? = nil) {
        self.pid = pid
        self.reason = reason
        self.date = date
    }

    /// How soon after a Quit a copy launchd starts counts as brought back. launchd waits at
    /// least its 10-second throttle, and a login comes much later than this.
    public static let revivalWindow: TimeInterval = 30

    /// Only a Quit by that very process keeps a copy standing by from running.
    public static func shouldRun(afterExitOf pid: Int32, note: ExitNote?) -> Bool {
        !(note?.pid == pid && note?.reason == .quit)
    }

    /// Whether launchd brought this copy back right after the last copy was quit on purpose. That
    /// happens when a copy crashes on its way out, which launchd takes for a failure. A Quit has
    /// to mean it, so that copy leaves. A copy started at the next login comes long after, and runs.
    /// - Parameter previous: The copy that held the lock last.
    public static func isRevivalAfterQuit(previous: Int32?, note: ExitNote?, now: Date = Date()) -> Bool {
        guard let previous, let note, note.pid == previous, note.reason == .quit, let date = note.date else {
            return false
        }
        let age = now.timeIntervalSince(date)
        return age >= 0 && age < revivalWindow
    }
}
