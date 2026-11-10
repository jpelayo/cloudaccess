// Apache 2 license - developer@infinitecontext.com

import Foundation
import Security

/// What the iPhone's Files extension needs a person to know about one drive. Files has no place
/// to say it, so the extension leaves it here and the app shows it. Only the extension writes
/// this, and only the app reads it, so there's never a lock between them.
public struct FilesNotes: Codable, Equatable, Sendable {
    /// Something another app saved into the drive. The drive is read-only, so it can't be sent,
    /// and it stays on this iPhone only.
    public struct Kept: Codable, Equatable, Sendable, Identifiable {
        /// The item's identifier in Files.
        public var id: String
        public var name: String
        /// Saved as a new file, rather than as an edit of one from the server.
        public var isNew: Bool
        public var date: Date

        public init(id: String, name: String, isNew: Bool, date: Date) {
            self.id = id
            self.name = name
            self.isNew = isNew
            self.date = date
        }

        /// What the app says about it, in the language shown.
        public var explanation: String {
            isNew
                ? Words.text("Saved here by another app. This drive is read-only, so it stays on this iPhone only. Copy it somewhere else in Files to keep it.")
                : Words.text("Changed in another app. This drive is read-only, so the change stays on this iPhone only. Copy the file somewhere else in Files to keep it.")
        }
    }

    /// A problem with the whole drive that Files can only show as an error.
    public enum Problem: String, Codable, Sendable {
        /// The server refused the sign-in, or its identity changed.
        case signIn
        /// The extension couldn't read the drive's password.
        case passwordUnreadable

        /// Whether pressing Try Again could fix it. A server may accept the account again, but
        /// nothing the app does lets Files read a password it can't.
        public var canTryAgain: Bool {
            switch self {
            case .signIn: true
            case .passwordUnreadable: false
            }
        }
    }

    /// Whether Try Again could help any of these drives. What's kept only on this iPhone doesn't
    /// count: a read-only drive would only refuse it again.
    public static func canTryAgain(_ notes: some Sequence<FilesNotes>) -> Bool {
        notes.contains { $0.problem?.canTryAgain == true }
    }

    public var kept: [Kept] = []
    public var problem: Problem?

    public init(kept: [Kept] = [], problem: Problem? = nil) {
        self.kept = kept
        self.problem = problem
    }

    public var isEmpty: Bool {
        kept.isEmpty && problem == nil
    }

    /// Lock files and temporary files that apps make while saving. They're refused like anything
    /// else, but listing them would only bury what matters.
    public static func isScratch(_ name: String) -> Bool {
        let lower = name.lowercased()
        return name.hasPrefix("~$") || name.hasPrefix(".~lock.") || name.hasPrefix(".sb-")
            || name.hasPrefix("~WRL") || name.hasPrefix("._") || name == ".DS_Store"
            || lower.hasSuffix(".tmp") || lower.hasSuffix(".swp")
    }

    /// Notes for a drive, or empty ones if there are none yet or they can't be read.
    public static func read(from url: URL) -> FilesNotes {
        guard let data = try? Data(contentsOf: url),
              let notes = try? JSONDecoder().decode(FilesNotes.self, from: data)
        else { return FilesNotes() }
        return notes
    }

    /// Changes a drive's notes, writing only if something changed. An empty set of notes removes
    /// the file.
    public static func update(at url: URL, _ change: (inout FilesNotes) -> Void) {
        let before = read(from: url)
        var after = before
        change(&after)
        guard after != before else { return }
        if after.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(after).write(to: url, options: .atomic)
    }

    /// What an outcome says about the drive's problem. Success clears it, and a refused sign-in or
    /// a password that can't be read sets it. Anything else, such as no network, says nothing
    /// either way, because it clears by itself.
    /// - Returns: The problem to record, nil to clear it, or `.none` to leave it as it is.
    public static func problem(after error: Error?) -> Problem?? {
        guard let error else { return .some(nil) }
        switch error {
        case RemoteError.unauthorized, RemoteError.vault, RemoteError.hostKeyChanged, RemoteError.hostKeyUnknown:
            return .some(.signIn)
        case DriveStore.StoreError.keychain(let status)
            where status == errSecItemNotFound || status == errSecMissingEntitlement:
            // Without the app's Keychain group, the extension either sees no password or is
            // refused one. Neither clears by itself. A locked iPhone does, so it isn't noted.
            return .some(.passwordUnreadable)
        default:
            return .none
        }
    }

    /// Records something kept on this iPhone, once, unless it's scratch.
    public mutating func keep(id: String, name: String, isNew: Bool, date: Date = Date()) {
        guard !Self.isScratch(name), !kept.contains(where: { $0.id == id }) else { return }
        kept.append(Kept(id: id, name: name, isNew: isNew, date: date))
    }

    /// Forgets what came back from the server, or was deleted here.
    public mutating func forget(id: String) {
        kept.removeAll { $0.id == id }
    }
}
