// Apache 2 license - developer@infinitecontext.com

import Foundation

/// What importing a drives file may do with each drive in it. A drive that isn't here yet starts on
/// Add, and every other on Skip, so one server folder never becomes two drives. A person can change
/// any step before importing. Nothing is ever removed: an import only adds drives or updates ones
/// already here.
public enum DrivesFileImport {
    public enum Platform: Sendable {
        case mac
        case phone
    }

    /// How a drive in the file stands against the drives on this device.
    public enum Situation: Equatable, Sendable {
        /// Not here yet.
        case new
        /// This drive is already here, under this ID.
        case alreadyHere(UUID)
        /// Another drive here has its name, so it can only be added under this one.
        case nameTaken(suggested: String)
        /// An earlier drive in the same file is on the same server folder, and that one is added.
        case listedTwice
        /// It can't be added on this device, for this reason, in the language shown.
        case notPossible(String)
    }

    public enum Step: Hashable, Sendable {
        case skip
        case add
        case addAs(String)
        case updatePasswords
        case updatePasswordsAndSettings

        /// In the language shown.
        public var title: String {
            switch self {
            case .skip: Words.text("Skip")
            case .add: Words.text("Add")
            case .addAs(let name): Words.format("Add as \u{201C}%@\u{201D}", name)
            case .updatePasswords: Words.text("Update passwords")
            case .updatePasswordsAndSettings: Words.text("Update passwords and settings")
            }
        }
    }

    public struct Row: Identifiable, Sendable {
        public let id: Int
        public let entry: DrivesFile.Entry
        public let situation: Situation
        /// Plain http sends the password readably, so each device asks for its own consent.
        public let needsInsecureConsent: Bool

        /// The steps a person can choose. Skip is always first. A drive already here, or listed
        /// twice, is never offered Add, so its server folder can't become a second drive.
        public var steps: [Step] {
            switch situation {
            case .new: [.skip, .add]
            case .alreadyHere: [.skip, .updatePasswords, .updatePasswordsAndSettings]
            case .nameTaken(let suggested): [.skip, .addAs(suggested)]
            case .listedTwice, .notPossible: [.skip]
            }
        }

        /// Where the row starts: a drive that isn't here yet is added, under a free name if its
        /// own is taken. Anything else starts on Skip, including a drive already here, whose
        /// passwords are only replaced when a person chooses that.
        public var startingStep: Step {
            switch situation {
            case .new: .add
            case .nameTaken(let suggested): .addAs(suggested)
            case .alreadyHere, .listedTwice, .notPossible: .skip
            }
        }

        /// What to tell a person about this drive before they choose, in the language shown.
        public var note: String? {
            switch situation {
            case .new: nil
            case .alreadyHere: Words.text("Already on this device.")
            case .nameTaken: Words.text("Another drive here has this name.")
            case .listedTwice: Words.text("Listed earlier in this file.")
            case .notPossible(let reason): reason
            }
        }
    }

    /// Sorts every drive in a file against the drives on this device, and against the drives
    /// earlier in the file that start on Add, so neither a server folder nor a name is added twice.
    public static func rows(
        for entries: [DrivesFile.Entry], among existing: [Connection], on platform: Platform
    ) -> [Row] {
        var rows: [Row] = []
        // What the rows so far add if they're left as they start.
        var adding: [Connection] = []
        for (index, entry) in entries.enumerated() {
            var found = situation(of: entry, among: existing, on: platform)
            switch found {
            case .new, .nameTaken:
                let incoming = entry.connection()
                if adding.contains(where: { !$0.requiresNewDrive(comparedTo: incoming) }) {
                    found = .listedTwice
                } else if (existing + adding).contains(where: { $0.displayName == entry.name }) {
                    found = .nameTaken(suggested: freeName(for: entry.name, among: existing + adding))
                }
            case .alreadyHere, .listedTwice, .notPossible:
                break
            }
            switch found {
            case .new: adding.append(entry.connection())
            case .nameTaken(let name): adding.append(entry.connection(named: name))
            case .alreadyHere, .listedTwice, .notPossible: break
            }
            rows.append(Row(
                id: index, entry: entry, situation: found, needsInsecureConsent: isPlainHTTP(entry.endpoint)))
        }
        return rows
    }

    static func situation(of entry: DrivesFile.Entry, among existing: [Connection], on platform: Platform) -> Situation {
        let incoming = entry.connection()
        if case .localFolder = entry.endpoint {
            return .notPossible(Words.text("A local test folder can't be moved to another device."))
        }
        // A file is untrusted input, held to the rules of a typed folder.
        guard ServerFolder.tidied(entry.rootPath, for: entry.endpoint) != nil else {
            return .notPossible(ServerFolder.refusal)
        }
        #if DEBUG
        guard incoming.isTestDrive else {
            return .notPossible(Words.format(
                "This test build only connects to a folder named %@.", Connection.testFolderName))
        }
        #endif
        if platform == .mac, let refusal = DriveEdit.modeRefusal(for: incoming) {
            return .notPossible(refusal)
        }
        if let same = existing.first(where: { !$0.requiresNewDrive(comparedTo: incoming) }) {
            return .alreadyHere(same.id)
        }
        if existing.contains(where: { $0.displayName == entry.name }) {
            return .nameTaken(suggested: freeName(for: entry.name, among: existing))
        }
        return .new
    }

    /// "Work 2", or the first number after it that's free.
    static func freeName(for name: String, among existing: [Connection]) -> String {
        let taken = Set(existing.map(\.displayName))
        var number = 2
        while taken.contains("\(name) \(number)") {
            number += 1
        }
        return "\(name) \(number)"
    }

    static func isPlainHTTP(_ endpoint: Connection.Endpoint) -> Bool {
        if case .webDAV(let url) = endpoint {
            return url.scheme?.lowercased() == "http"
        }
        return false
    }

    /// The new drive an Add step makes, with an ID of its own. Consent to plain http is only ever
    /// this device's own.
    public static func newDrive(for row: Row, step: Step, allowsInsecure: Bool) -> Connection? {
        var connection: Connection
        switch step {
        case .add:
            connection = row.entry.connection()
        case .addAs(let name):
            connection = row.entry.connection(named: name)
        default:
            return nil
        }
        if row.needsInsecureConsent {
            guard allowsInsecure else { return nil }
            connection.allowsInsecure = true
        }
        return connection
    }

    /// One part of a step, with what takes it back.
    public struct Action {
        public let run: () async throws -> Void
        public let undo: () async -> Void

        public init(run: @escaping () async throws -> Void, undo: @escaping () async -> Void = {}) {
            self.run = run
            self.undo = undo
        }
    }

    /// Runs one drive's step so it either finishes or changes nothing. If any part fails, the
    /// parts already done are taken back, newest first, and the error is passed on. Each step is
    /// on its own, so one drive's failure never touches another's.
    public static func allOrNothing(
        _ actions: [Action], isolation: isolated (any Actor)? = #isolation
    ) async throws {
        var done: [Action] = []
        for action in actions {
            do {
                try await action.run()
                done.append(action)
            } catch {
                for finished in done.reversed() {
                    await finished.undo()
                }
                throw error
            }
        }
    }

    /// The drive already here as an Update step leaves it. Its own ID, name and pins stay, so
    /// everything kept for it on this device still describes it.
    public static func updatedDrive(_ existing: Connection, for row: Row, step: Step) -> Connection? {
        switch step {
        case .updatePasswords:
            return existing
        case .updatePasswordsAndSettings:
            var updated = existing
            updated.settings = row.entry.settings
            return updated
        default:
            return nil
        }
    }
}
