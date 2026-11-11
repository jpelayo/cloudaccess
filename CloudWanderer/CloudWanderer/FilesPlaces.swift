// Apache 2 license - developer@infinitecontext.com

import CloudCore
import FileProvider
import Foundation
import Observation

/// The app's drives, opened once per launch. In a build with the App Group they live where the
/// Files extension can read them, and they move there the first time.
enum PhoneDrives {
    private static let opened: (store: DriveStore, isShared: Bool, moves: [UUID: PasswordMove.Outcome]) = {
        let opened = DriveStore.phone(ownFolder: URL.applicationSupportDirectory, shared: DriveStore.phoneShared())
        // Where the Files extension can read them. Only the app can, since only it reads the old place.
        let moves = opened.isShared ? opened.store.movePasswordsHere() : [:]
        // Passwords saved before this stayed in encrypted backups. Now they stay on this iPhone.
        opened.store.keepSavedPasswordsOnThisDevice()
        return (opened.store, opened.isShared, moves)
    }()

    static var store: DriveStore { opened.store }

    /// What moving the passwords did at this launch, for the log. It can't be logged while the
    /// store is opening, because the log is in the store.
    static var passwordMoves: [UUID: PasswordMove.Outcome] { opened.moves }

    /// Whether the Files extension can see the drives. Without it nothing is put in Files.
    static var reachFiles: Bool { opened.isShared }

    /// What the Files extension last measured.
    static var memoryReport: MemoryReport? {
        DriveStore.phoneShared().flatMap { MemoryReport.read(from: $0.memoryReportURL) }
    }

    /// What the Files extension left for a person to know about a drive.
    static func notes(for drive: UUID) -> FilesNotes {
        guard reachFiles, let shared = DriveStore.phoneShared() else { return FilesNotes() }
        return FilesNotes.read(from: shared.filesNotesURL(for: drive))
    }
}

/// Puts each drive Files can show there, as a location named after it, and takes away the ones
/// that shouldn't be there. It runs at every launch, after a drive is added or removed, and when
/// the app comes back, so a step a crash interrupted is finished next time.
@Observable
final class FilesPlaces {
    /// Drives that should be in Files and couldn't be put there, with why.
    private(set) var problems: [UUID: String] = [:]
    /// Drives whose location the person switched off in Files.
    private(set) var switchedOff: Set<UUID> = []
    /// What the Files extension left about each drive.
    private(set) var notes: [UUID: FilesNotes] = [:]
    /// Try Again is waiting for the extension's answer.
    private(set) var isTryingAgain = false
    /// The last Try Again ended with Files still refused, until the drives are next checked.
    private(set) var isStillRefused = false
    /// Set while an uninstall runs, so coming back to the app can't put a location back between
    /// its steps.
    var isPaused = false
    private var updating = false
    private var again = false
    private var isListening = false

    /// Whether Try Again could help: a location that couldn't be added, or a sign-in the server
    /// may accept again. Not a password Files can't read, which no retry changes.
    var canTryAgain: Bool {
        !problems.isEmpty || FilesNotes.canTryAgain(notes.values)
    }

    /// Matches the locations to the drives. A call that arrives while one is running makes that
    /// one run again once it ends, so a drive added during the launch pass isn't missed.
    func update(drives: [Connection]) async {
        guard PhoneDrives.reachFiles, !isPaused else { return }
        guard !updating else {
            again = true
            return
        }
        updating = true
        defer { updating = false }
        var latest = drives
        repeat {
            again = false
            await reconcile(latest)
            latest = (try? PhoneDrives.store.connections()) ?? latest
        } while again
    }

    /// Tells iOS to try again everything it stopped trying, "can't sync" included, adds the
    /// locations that couldn't be added, and has Files sign in to each drive again. Only a person
    /// asks for this, so a change that's refused anyway is refused once, not in a loop.
    func tryAgain(drives: [Connection]) async {
        guard !isTryingAgain, !isPaused else { return }
        isTryingAgain = true
        defer { isTryingAgain = false }
        let before = notes
        AppLog.record("Files: Try Again pressed")
        for domain in (try? await NSFileProviderManager.domains()) ?? [] {
            guard let manager = NSFileProviderManager(for: domain) else { continue }
            try? await manager.signalErrorResolved(NSFileProviderError(.cannotSynchronize))
        }
        await update(drives: drives)
        let waitingOn = before.filter { $0.value.problem != nil }
        guard !waitingOn.isEmpty else { return }
        // Without waiting, nothing would seem to happen.
        await awaitAnswer(after: before)
        for drive in drives where waitingOn[drive.id] != nil {
            let outcome = switch notes[drive.id]?.problem {
            case nil: "Files signed in again"
            case .signIn?: "Files still can't sign in"
            case .passwordUnreadable?: "Files can't read the password"
            }
            AppLog.record("\(drive.displayName): \(outcome)")
        }
        isStillRefused = FilesNotes.canTryAgain(notes.values)
    }

    /// Matches the locations, then listens for drives Files had trouble with: the extension
    /// checks them now, and its answer comes a few seconds later.
    func refresh(drives: [Connection]) async {
        await update(drives: drives)
        guard !isListening, !isTryingAgain, notes.values.contains(where: { $0.problem != nil }) else { return }
        isListening = true
        defer { isListening = false }
        await awaitAnswer(after: notes)
    }

    /// Re-reads the extension's notes until a drive's problem changes, or 20 seconds pass. The
    /// extension signs in when Files asks it for changes, at most every 20 seconds.
    private func awaitAnswer(after before: [UUID: FilesNotes]) async {
        for _ in 0..<20 {
            try? await Task.sleep(for: .seconds(1))
            let latest = notes.keys.reduce(into: [UUID: FilesNotes]()) { $0[$1] = PhoneDrives.notes(for: $1) }
            if latest.mapValues(\.problem) != before.mapValues(\.problem) {
                notes = latest
                return
            }
        }
    }

    /// Takes a drive's location out of Files, before the drive's password goes, so the extension
    /// isn't left asking for a password that's already gone.
    func removeLocation(of drive: Connection) async {
        guard PhoneDrives.reachFiles, let domains = try? await NSFileProviderManager.domains() else { return }
        for domain in domains where domain.identifier.rawValue == drive.id.uuidString {
            try? await NSFileProviderManager.remove(domain)
        }
    }

    private func reconcile(_ drives: [Connection]) async {
        isStillRefused = false
        guard let domains = try? await NSFileProviderManager.domains() else { return }
        let plan = FilesLocations.plan(
            drives: drives,
            locations: Dictionary(domains.map { ($0.identifier.rawValue, $0.displayName) }) { first, _ in first })
        // One at a time, never all at once: each holds only copies of what's on the server.
        for domain in domains where plan.remove.contains(domain.identifier.rawValue) {
            try? await NSFileProviderManager.remove(domain)
        }
        var found: [UUID: String] = [:]
        // Adding a location that's already there renames it, which Apple says keeps what it holds.
        for location in plan.add + plan.rename {
            let domain = NSFileProviderDomain(
                identifier: NSFileProviderDomainIdentifier(location.id.uuidString), displayName: location.name)
            domain.supportsSyncingTrash = false
            do {
                try await NSFileProviderManager.add(domain)
            } catch {
                found[location.id] = error.localizedDescription
            }
        }
        problems = found
        var off: Set<UUID> = []
        var read: [UUID: FilesNotes] = [:]
        for domain in (try? await NSFileProviderManager.domains()) ?? [] {
            guard let id = UUID(uuidString: domain.identifier.rawValue) else { continue }
            if !domain.userEnabled {
                off.insert(id)
            }
            read[id] = PhoneDrives.notes(for: id)
            guard let manager = NSFileProviderManager(for: domain) else { continue }
            // Nothing checks the server in the background on the iPhone, so opening the app is
            // when Files hears what changed, and when it stops holding back after an outage.
            for code in [NSFileProviderError.Code.serverUnreachable, .notAuthenticated] {
                try? await manager.signalErrorResolved(NSFileProviderError(code))
            }
            do {
                try await manager.signalEnumerator(for: .workingSet)
            } catch let error as NSFileProviderError where error.code == .domainDisabled {
                off.insert(id)
            } catch {}
        }
        switchedOff = off
        notes = read
    }
}
