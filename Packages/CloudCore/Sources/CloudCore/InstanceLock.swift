// Apache 2 license - developer@infinitecontext.com

import Foundation

/// An exclusive lock on a file, which decides which copy of the Mac app runs. The system takes it
/// in one step, so two copies starting together can't both get it, and lets go of it however its
/// holder ends, a crash included.
///
/// Nothing else can decide this. LaunchServices only lists a copy launchd started once AppKit has
/// checked it in, so two copies starting together can each miss the other. And a sandboxed app
/// most likely can't ask whether another process is alive: `kill(pid, 0)` fails with `EPERM`,
/// which the old wait read as "it ended", letting a second copy run beside the first.
public final class InstanceLock {
    /// Who holds the lock, as the holder wrote it.
    public struct Holder: Equatable, Sendable {
        public var pid: Int32
        /// Started by the launch agent, rather than opened by hand.
        public var isAgent: Bool

        public init(pid: Int32, isAgent: Bool) {
            self.pid = pid
            self.isAgent = isAgent
        }
    }

    private var descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        release()
    }

    /// Takes the lock if nobody holds it.
    /// - Returns: Nil if somebody holds it, or the file can't be opened.
    public static func take(_ url: URL) -> InstanceLock? {
        guard let descriptor = open(url) else { return nil }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return nil
        }
        return InstanceLock(descriptor: descriptor)
    }

    /// Takes the lock, tried for up to a second. Another copy only looking at it holds it for a
    /// moment, and that mustn't count as it being taken.
    public static func takeSoon(_ url: URL) -> InstanceLock? {
        for _ in 0..<10 {
            if let lock = take(url) {
                return lock
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return nil
    }

    /// Waits until nobody holds the lock, then takes it. It blocks the calling thread.
    /// - Returns: Nil only if the file can't be opened.
    public static func wait(for url: URL) -> InstanceLock? {
        guard let descriptor = open(url) else { return nil }
        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else {
                close(descriptor)
                return nil
            }
        }
        return InstanceLock(descriptor: descriptor)
    }

    /// Whether somebody holds the lock now. False too if the file can't be opened.
    public static func isHeld(_ url: URL) -> Bool {
        guard let descriptor = open(url) else { return false }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            return errno == EWOULDBLOCK
        }
        flock(descriptor, LOCK_UN)
        return false
    }

    /// Who last held the lock, as they wrote it. A holder that has ended leaves its record behind.
    public static func holder(_ url: URL) -> Holder? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n")
        guard lines.count >= 2, let pid = Int32(lines[0]) else { return nil }
        return Holder(pid: pid, isAgent: lines[1] == "agent")
    }

    /// Writes who holds the lock, for the copies that find it taken.
    public func record(_ holder: Holder) {
        guard descriptor >= 0 else { return }
        let text = "\(holder.pid)\n\(holder.isAgent ? "agent" : "opened")\n"
        ftruncate(descriptor, 0)
        _ = text.withCString { pwrite(descriptor, $0, strlen($0), 0) }
    }

    /// Lets go of the lock. Ending the process does the same.
    public func release() {
        guard descriptor >= 0 else { return }
        close(descriptor)
        descriptor = -1
    }

    private static func open(_ url: URL) -> Int32? {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = Darwin.open(url.path(percentEncoded: false), O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        return descriptor >= 0 ? descriptor : nil
    }
}
