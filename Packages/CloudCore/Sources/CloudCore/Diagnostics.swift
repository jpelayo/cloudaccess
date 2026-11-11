// Apache 2 license - developer@infinitecontext.com

import Foundation
import Synchronization

/// A small log, shared by the app and its extension, that only leaves this device when a person
/// exports it. It records what happened to drives, never file contents.
///
/// Each day has its own file, so a person can find a day in Finder and nothing has to coordinate
/// between processes. A month is forgotten, and a bad day can't make the folder huge.
public struct Diagnostics: Sendable {
    public let folder: URL
    /// Where older builds kept it, so what they wrote comes across.
    private let earlierDirectory: URL?

    private static let daysKept = 30.0
    /// A day past this size starts its file again, keeping one older file.
    private static let maximumBytesPerDay = 1_000_000
    /// Checked when a file starts, so a very bad day can go over by that day's own files.
    private static let maximumTotalBytes = 5_000_000

    public init(directory: URL, earlierDirectory: URL? = nil) {
        folder = directory
        self.earlierDirectory = earlierDirectory
    }

    /// Today's file, which is the one to show a person.
    public var file: URL {
        file(on: Date())
    }

    /// The day as the lines inside it give it, so a file never holds another file's date.
    private func file(on day: Date) -> URL {
        folder.appendingPathComponent("diagnostics-\(day.ISO8601Format().prefix(10)).log")
    }

    /// Removes anything that could be a secret, in case an error message carried one.
    public static func redact(_ text: String) -> String {
        var cleaned = text
        // user:password@host in an address.
        cleaned = cleaned.replacingOccurrences(
            of: #"://[^/\s:@]+:[^/\s@]+@"#, with: "://[redacted]@", options: .regularExpression)
        // key=value and key: value pairs that name a secret. A quoted value can hold spaces, so
        // it goes whole, up to its closing quote or the end of the line.
        cleaned = cleaned.replacingOccurrences(
            of: #"(?i)(password|passphrase|pass|secret|token)(["']?\s*[=:]\s*)("(?:[^"\\\n]|\\.)*"?|'(?:[^'\\\n]|\\.)*'?|[^\s"',}]+)"#,
            with: "$1$2[redacted]", options: .regularExpression)
        // A sign-in header, whatever its scheme, and a bearer token on its own.
        cleaned = cleaned.replacingOccurrences(
            of: #"(?i)(authorization["']?\s*[=:]\s*)[^\n]+"#,
            with: "$1[redacted]", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(
            of: #"(?i)\bbearer\s+[A-Za-z0-9+/._~=-]{8,}"#,
            with: "bearer [redacted]", options: .regularExpression)
        // A private key, whole.
        cleaned = cleaned.replacingOccurrences(
            of: #"-----BEGIN[^-]*PRIVATE KEY-----[\s\S]*?-----END[^-]*PRIVATE KEY-----"#,
            with: "[redacted key]", options: .regularExpression)
        return cleaned
    }

    /// Set once an uninstall has deleted the log, so nothing in this process writes a new one.
    private static let silenced = Mutex(false)

    /// Stops this process recording, for good. An uninstall calls it before deleting the log.
    public static func silence() {
        silenced.withLock { $0 = true }
    }

    public func record(_ message: String, now: Date = Date()) {
        guard !Self.silenced.withLock({ $0 }) else { return }
        guard let data = "\(now.ISO8601Format()) \(Self.redact(message))\n".data(using: .utf8) else { return }
        let target = file(on: now)
        let manager = FileManager.default
        let size = (try? manager.attributesOfItem(atPath: target.path))?[.size] as? Int
        let isFull = size.map { $0 > Self.maximumBytesPerDay } ?? false
        if isFull {
            let older = target.deletingPathExtension().appendingPathExtension("old.log")
            try? manager.removeItem(at: older)
            try? manager.moveItem(at: target, to: older)
        }
        // A new file is rare enough that tidying then costs nothing.
        if size == nil || isFull {
            tidy(now: now)
        }
        append(data, to: target)
    }

    /// The app and each drive's extension write here at the same moment. Only appending in the
    /// system's own way keeps their lines whole: seeking to the end first lets one overwrite another.
    private func append(_ data: Data, to target: URL) {
        let descriptor = open(target.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard descriptor >= 0 else { return }
        try? FileHandle(fileDescriptor: descriptor, closeOnDealloc: true).write(contentsOf: data)
    }

    /// Makes the folder, brings over what an older build wrote, and forgets what's past its time.
    /// Two processes can do this together: a move or a removal that loses the race changes nothing.
    private func tidy(now: Date) {
        let manager = FileManager.default
        try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
        if let earlierDirectory {
            for name in ["diagnostics.log", "diagnostics.old.log"] {
                try? manager.moveItem(
                    at: earlierDirectory.appendingPathComponent(name), to: folder.appendingPathComponent(name))
            }
        }
        let found = logs()
        let forgetBefore = now.addingTimeInterval(-Self.daysKept * 86_400)
        var total = found.reduce(0) { $0 + $1.size }
        for log in found where log.modified < forgetBefore || total > Self.maximumTotalBytes {
            try? manager.removeItem(at: log.url)
            total -= log.size
        }
    }

    /// Every log in the folder, oldest first.
    private func logs() -> [(url: URL, modified: Date, size: Int)] {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        let found = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: Array(keys))
        return (found ?? [])
            .filter { $0.pathExtension == "log" }
            .compactMap { url in
                guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
                return (url, values.contentModificationDate ?? .distantPast, values.fileSize ?? 0)
            }
            .sorted { $0.modified < $1.modified }
    }

    /// Everything still kept, for a person to save and send.
    public func exportedText(header: String) -> String {
        tidy(now: Date())
        let text = logs().compactMap { try? String(contentsOf: $0.url, encoding: .utf8) }.joined()
        // Redacted again on the way out, so what was written by an older build is covered too.
        return Self.redact(header + "\n\n" + text)
    }

    /// The latest lines across every day kept, oldest first, for reading on the device.
    public func recentLines(limit: Int) -> [String] {
        var kept: [String] = []
        for log in logs().reversed() where kept.count < limit {
            guard let text = try? String(contentsOf: log.url, encoding: .utf8) else { continue }
            let lines = text.split(separator: "\n").map { Self.redact(String($0)) }
            kept = lines.suffix(limit - kept.count) + kept
        }
        return kept
    }
}

extension Diagnostics {
    /// Words that can appear in a failure, and say what sort it was without saying anything else.
    private static let causes = [
        "too many", "refused", "reset", "timed out", "timeout", "EOF", "no such host", "tls", "certificate",
        "answer was lost", "didn't make sense", "too slow", "offline", "broken pipe", "no route",
    ]

    /// The kind of failure and nothing else: no name, path or server text, so it's safe to keep in
    /// a release build, where a failure otherwise leaves no trace.
    public static func kind(of error: Error) -> String {
        switch error {
        case RemoteError.server(let status):
            return "server \(status)"
        case RemoteError.unreachable(let message):
            let found = causes.filter { message.localizedCaseInsensitiveContains($0) }
            return "unreachable (\(found.isEmpty ? "other" : found.joined(separator: ", ")))"
        case RemoteError.vault(let problem):
            return "vault \(problem.rawValue)"
        case DriveStore.StoreError.keychain(let status):
            return "keychain \(status)"
        case is CancellationError:
            return "cancelled"
        default:
            let mirror = Mirror(reflecting: error)
            if let label = mirror.children.first?.label {
                // A case carrying a path or a message: only its name.
                return label
            }
            if mirror.displayStyle == .enum {
                // A case with nothing attached prints as its name alone.
                return String(describing: error)
            }
            let plain = error as NSError
            return "\(plain.domain) \(plain.code)"
        }
    }
}
