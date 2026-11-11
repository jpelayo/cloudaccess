// Apache 2 license - developer@infinitecontext.com

import Foundation

/// Removing every drive, and everything the app keeps on this device, before the app is deleted.
/// Deleting an app gives it no chance to clean up, so this is the only moment it can. Nothing here
/// touches a server: the files there, `.cloudmount` and each encrypted drive's marker all stay.
///
/// This holds the steps and what each one found. The apps do the work. A step passes only when the
/// app's check afterwards finds nothing left, never because a call returned without an error.
public enum Uninstall {
    public enum Platform: Sendable, Equatable {
        case mac
        case phone
    }

    public enum Step: Hashable, Sendable {
        /// The drive list reads, and the system lists this app's locations.
        case checkFirst
        /// Nothing is left to upload.
        case waitForUploads
        case removeDrive(id: UUID, name: String)
        /// A location the system has with no drive behind it.
        case removeOrphanLocation(identifier: String)
        /// Nothing in the app can create a drive's database again once it's deleted.
        case stopBackgroundWork
        case deleteLocalData
        case deletePasswords
        /// Every check again, together.
        case confirmNothingLeft
        /// Last of all, at Quit, because turning it off can end the app.
        case turnOffLaunchAtLogin
    }

    /// Words for a step, in English for the report and in the language shown.
    public struct Line: Equatable, Sendable {
        public let english: String
        public let shown: String

        init(english: String, shown: String) {
            self.english = english
            self.shown = shown
        }

        init(_ key: String, _ values: CVarArg...) {
            english = Words.english(key, values)
            shown = Words.format(key, arguments: values)
        }

        /// A sentence about a failure: the shown words carry the system's own description, and
        /// the English only the kind of failure, as the log does.
        init(_ key: String, error: Error) {
            english = Words.english(key, [Diagnostics.kind(of: error)])
            shown = Words.format(key, arguments: [error.localizedDescription])
        }
    }

    public enum State: Equatable, Sendable {
        case pending
        case running(Line?)
        case passed(Line?)
        case failed(reason: Line, leftAs: Line)

        public var isPassed: Bool {
            if case .passed = self { true } else { false }
        }
    }

    /// Why a drive is holding up the wait.
    public enum Hold: Sendable {
        case offline
        case failing
        case uploading
    }

    /// Something a check found still there.
    public enum Leftover: Equatable, Sendable {
        /// A location in Finder or Files, by its identifier.
        case location(String)
        case record
        case password
        case passwords
        case loginItem
        /// A file or folder on this device, by its path.
        case file(String)

        func line(on platform: Platform) -> Line {
            switch self {
            case .location(let identifier):
                platform == .mac
                    ? .init("the Finder location %@", identifier)
                    : .init("the Files location %@", identifier)
            case .record: .init("the drive's record")
            case .password: .init("the drive's password")
            case .passwords: .init("passwords in the Keychain")
            case .loginItem: .init("the login item")
            case .file(let path): .init(english: path, shown: path)
            }
        }
    }

    /// What the app left in its temporary folder: a folder named with a UUID for each drives file
    /// it made to send, and a shared log. Only these go, because the system and its frameworks
    /// use the same folder.
    public static func temporaryItems(in folder: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names
            .filter { UUID(uuidString: $0) != nil || ($0.hasPrefix("CloudWanderer log ") && $0.hasSuffix(".txt")) }
            .sorted()
            .map { folder.appendingPathComponent($0) }
    }

    /// Which locations the system has that no drive accounts for.
    /// - Parameters:
    ///   - domains: The identifiers the system lists for this app.
    ///   - drives: Every saved drive, whatever its state.
    public static func orphanLocations(domains: Set<String>, drives: [Connection]) -> [String] {
        domains.subtracting(drives.map(\.id.uuidString)).sorted()
    }

    /// One uninstall, from the first check to the last.
    public struct Run: Equatable, Sendable {
        public let platform: Platform
        public let started: Date
        public let steps: [Step]
        public private(set) var states: [Step: State]
        /// What the system kept of files that hadn't uploaded, by path. The list the app keeps of
        /// them is deleted with the rest, so this is where a person still finds them.
        public private(set) var keptFiles: [String] = []
        /// What's holding up the wait, drive by drive.
        public private(set) var holds: [Line] = []
        private var waitBegan: Int?
        private var waitLeft: Int?
        private var history: [Entry] = []

        struct Entry: Equatable, Sendable {
            let date: Date
            let step: Step
            let state: State
        }

        /// - Parameters:
        ///   - drives: Every saved drive, ejected, half-added and half-removed ones included.
        ///   - orphanLocations: From `Uninstall.orphanLocations(domains:drives:)`.
        public init(platform: Platform, drives: [Connection], orphanLocations: [String], now: Date = Date()) {
            self.platform = platform
            started = now
            var steps: [Step] = [.checkFirst]
            if platform == .mac {
                steps.append(.waitForUploads)
            }
            // A damaged list could hold a drive twice. It's removed once.
            var seen = Set<UUID>()
            for drive in drives where seen.insert(drive.id).inserted {
                steps.append(Step.removeDrive(id: drive.id, name: drive.displayName))
            }
            for identifier in orphanLocations {
                steps.append(Step.removeOrphanLocation(identifier: identifier))
            }
            if platform == .mac {
                steps.append(.stopBackgroundWork)
            }
            steps += [.deleteLocalData, .deletePasswords, .confirmNothingLeft]
            if platform == .mac {
                steps.append(.turnOffLaunchAtLogin)
            }
            self.steps = steps
            states = Dictionary(steps.map { ($0, State.pending) }, uniquingKeysWith: { first, _ in first })
        }

        public func state(of step: Step) -> State {
            states[step] ?? .pending
        }

        /// The first step that hasn't passed.
        public var next: Step? {
            steps.first { !state(of: $0).isPassed }
        }

        public var failedStep: Step? {
            steps.first { if case .failed = state(of: $0) { true } else { false } }
        }

        /// Every step has passed but launch at login, which turns off at Quit.
        public var isFinished: Bool {
            counted.allSatisfy { state(of: $0).isPassed }
        }

        /// Whether anything has been removed yet. Until then, stopping leaves everything as it was.
        public var hasChangedAnything: Bool {
            steps.contains { step in
                switch step {
                case .checkFirst, .waitForUploads: false
                default: state(of: step) != .pending
                }
            }
        }

        /// How far along it is, from 0 to 1. The wait counts as the files go.
        public var fraction: Double {
            let all = counted
            guard !all.isEmpty else { return 1 }
            var done = Double(all.filter { state(of: $0).isPassed }.count)
            if case .running = state(of: .waitForUploads), let waitBegan, let waitLeft, waitBegan > 0 {
                done += Double(waitBegan - min(waitLeft, waitBegan)) / Double(waitBegan)
            }
            return done / Double(all.count)
        }

        private var counted: [Step] {
            steps.filter { $0 != .turnOffLaunchAtLogin }
        }

        public mutating func begin(_ step: Step, note: Line? = nil, now: Date = Date()) {
            set(step, .running(note), now: now)
        }

        /// The files still to upload, counted again after each check. It passes at zero, and only
        /// then. The count can go up as well as down: a person may still be saving.
        public mutating func waiting(filesLeft: Int, holds: [Line] = [], now: Date = Date()) {
            self.holds = filesLeft == 0 ? [] : holds
            if filesLeft == 0 {
                waitLeft = 0
                set(.waitForUploads, .passed(.allUploaded), now: now)
                return
            }
            waitBegan = max(waitBegan ?? 0, filesLeft)
            waitLeft = filesLeft
            let note = Line.waiting(files: filesLeft)
            // Each count is logged once, not on every check.
            if state(of: .waitForUploads) != .running(note) {
                set(.waitForUploads, .running(note), now: now)
            }
        }

        /// Ends a step with what its check found. Anything still there fails it, whatever the
        /// call that removed it said.
        /// - Parameters:
        ///   - leftovers: What the check found still there.
        ///   - leftAs: What a failure leaves, in plain words.
        public mutating func finish(
            _ step: Step, leftovers: [Leftover], note: Line? = nil, leftAs: Line, now: Date = Date()
        ) {
            if leftovers.isEmpty {
                set(step, .passed(note), now: now)
            } else {
                let found = leftovers.map { $0.line(on: platform) }
                set(step, .failed(reason: .stillThere(found), leftAs: leftAs), now: now)
            }
        }

        public mutating func fail(_ step: Step, reason: Line, leftAs: Line, now: Date = Date()) {
            set(step, .failed(reason: reason, leftAs: leftAs), now: now)
        }

        public mutating func keep(filesAt path: String) {
            if !keptFiles.contains(path) {
                keptFiles.append(path)
            }
        }

        /// Puts the failed step back, so the run starts again there. A failed last check also puts
        /// back every step that removes something, because what it found belongs to one of them,
        /// and each of them is safe to run again.
        public mutating func tryAgain(now: Date = Date()) {
            guard let failedStep else { return }
            var again = [failedStep]
            if failedStep == .confirmNothingLeft {
                again += steps.filter { step in
                    switch step {
                    case .checkFirst, .waitForUploads, .confirmNothingLeft, .turnOffLaunchAtLogin: false
                    default: true
                    }
                }
            }
            for step in steps where again.contains(step) {
                set(step, .pending, now: now)
            }
        }

        private mutating func set(_ step: Step, _ state: State, now: Date) {
            states[step] = state
            history.append(Entry(date: now, step: step, state: state))
        }

        /// What happened, in English, for a person to keep: the uninstall deletes the log. It
        /// names drives and files on this device, never a server or a password.
        public func report() -> String {
            let device = platform == .mac ? "Mac" : "iPhone"
            let app = platform == .mac ? "CloudAccess" : "CloudWanderer"
            var lines = [
                "\(app) uninstall report",
                "Device: \(device)",
                "Started: \(started.ISO8601Format())",
                "Files on servers were not changed.",
                "",
            ]
            for step in steps {
                lines.append(Self.reportLine(Step.title(step, on: platform).english, state(of: step)))
            }
            if !keptFiles.isEmpty {
                lines += ["", "Files that hadn't uploaded, kept on this \(device):"]
                lines += keptFiles
            }
            lines += ["", "History:"]
            for entry in history {
                let time = entry.date.ISO8601Format()
                lines.append("\(time) " + Self.reportLine(Step.title(entry.step, on: platform).english, entry.state))
            }
            return Diagnostics.redact(lines.joined(separator: "\n")) + "\n"
        }

        private static func reportLine(_ title: String, _ state: State) -> String {
            switch state {
            case .pending:
                "Not done: \(title)"
            case .running(let note):
                ["Running: \(title).", note?.english].compactMap { $0 }.joined(separator: " ")
            case .passed(let note):
                ["Passed: \(title).", note?.english].compactMap { $0 }.joined(separator: " ")
            case .failed(let reason, let leftAs):
                "Failed: \(title). \(reason.english) \(leftAs.english)"
            }
        }
    }
}

// MARK: Words

extension Uninstall.Step {
    /// The step's name in the list.
    public static func title(_ step: Self, on platform: Uninstall.Platform) -> Uninstall.Line {
        let mac = platform == .mac
        return switch step {
        case .checkFirst: .init("Check before starting")
        case .waitForUploads: .init("Wait for uploads")
        case .removeDrive(_, let name): .init("Remove %@", name)
        case .removeOrphanLocation:
            mac ? .init("Remove a Finder location with no drive") : .init("Remove a Files location with no drive")
        case .stopBackgroundWork: .init("Stop checking drives")
        case .deleteLocalData: mac ? .init("Delete data on this Mac") : .init("Delete data on this iPhone")
        case .deletePasswords: .init("Delete passwords")
        case .confirmNothingLeft: .init("Confirm nothing is left")
        case .turnOffLaunchAtLogin: .init("Turn off launch at login")
        }
    }
}

extension Uninstall.Line {
    // What a step found.

    public static func found(drives: Int) -> Self { .init("Found %lld drives.", drives) }
    public static func waiting(files: Int) -> Self { .init("Waiting for %lld files to upload.", files) }
    public static let allUploaded = Self("All files uploaded.")
    public static func removed(_ platform: Uninstall.Platform) -> Self {
        platform == .mac ? .init("Removed from Finder. Password deleted.") : .init("Removed from Files. Password deleted.")
    }
    public static let removedKeepingFiles = Self(
        "Removed from Finder. Password deleted. Files that hadn't uploaded were kept on this Mac.")
    public static let locationRemoved = Self("Removed.")
    public static let stopped = Self("Stopped.")
    public static func deleted(items: Int) -> Self { .init("Deleted %lld items.", items) }
    public static func passwordsDeleted(_ count: Int) -> Self {
        count == 0 ? .init("None were left.") : .init("Deleted %lld passwords.", count)
    }
    public static func nothingLeft(_ platform: Uninstall.Platform) -> Self {
        platform == .mac
            ? .init("No drives, Finder locations, passwords or data files are left.")
            : .init("No drives, Files locations, passwords or data files are left.")
    }
    public static let turnsOffAtQuit = Self("Turns off when you quit.")

    /// Why a drive is holding up the wait.
    public static func hold(_ hold: Uninstall.Hold, drive: String) -> Self {
        switch hold {
        case .offline: .init("%@: the server can't be reached.", drive)
        case .failing: .init("%@: some files can't upload. The drive's details say why.", drive)
        case .uploading: .init("%@: uploading.", drive)
        }
    }

    // Why a step failed.

    public static func cantReadDrives(_ error: Error) -> Self {
        .init("The drive list can't be read: %@", error: error)
    }
    public static func cantListLocations(_ error: Error, _ platform: Uninstall.Platform) -> Self {
        platform == .mac
            ? .init("macOS didn't list this app's locations: %@", error: error)
            : .init("iOS didn't list this app's locations: %@", error: error)
    }
    public static func refused(_ error: Error, _ platform: Uninstall.Platform) -> Self {
        platform == .mac ? .init("macOS refused: %@", error: error) : .init("iOS refused: %@", error: error)
    }
    public static func keychain(_ status: OSStatus) -> Self {
        .init("The Keychain couldn't be used (error %lld).", Int(status))
    }
    public static let didNotStop = Self("Checking drives didn't stop.")
    static func stillThere(_ items: [Self]) -> Self {
        .init(
            english: Words.english("Still there: %@", [items.map(\.english).joined(separator: ", ")]),
            shown: Words.format("Still there: %@", items.map(\.shown).joined(separator: ", ")))
    }

    // What a failure leaves.

    public static func nothingChanged(_ platform: Uninstall.Platform) -> Self {
        .init("Nothing was changed.")
    }
    public static func driveStillThere(_ platform: Uninstall.Platform) -> Self {
        platform == .mac
            ? .init("The drive is still in Finder, with its password.")
            : .init("The drive is still in Files, with its password.")
    }
    public static func driveHalfRemoved(_ platform: Uninstall.Platform) -> Self {
        platform == .mac
            ? .init("The drive is out of Finder. Its record or password is still on this Mac.")
            : .init("The drive is out of Files. Its record or password is still on this iPhone.")
    }
    public static func locationStillThere(_ platform: Uninstall.Platform) -> Self {
        platform == .mac ? .init("The location is still in Finder.") : .init("The location is still in Files.")
    }
    public static func itemsLeft(_ platform: Uninstall.Platform) -> Self {
        platform == .mac
            ? .init("The items named are still on this Mac.")
            : .init("The items named are still on this iPhone.")
    }
    public static let passwordsLeft = Self("Some passwords are still in the Keychain.")
    public static func dataStillHere(_ platform: Uninstall.Platform) -> Self {
        platform == .mac
            ? .init("The data on this Mac hasn't been deleted yet.")
            : .init("The data on this iPhone hasn't been deleted yet.")
    }
}
