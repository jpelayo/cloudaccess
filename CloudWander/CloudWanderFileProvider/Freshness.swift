// Apache 2 license - developer@infinitecontext.com

import CloudCore
import FileProvider
import FileProviderShell
import SyncCore

/// Keeps Files up to date while it uses this extension. On the Mac the app checks the server and
/// tells macOS; on the iPhone nothing runs in the background, so this checks while iOS keeps the
/// extension running, and whenever Files asks for changes, such as after the app is opened.
actor Freshness {
    private let connector: Connector
    private let domain: NSFileProviderDomain
    private let notes: DriveNotes
    private var loop: Task<Void, Never>?
    private var polling: Task<Bool, Never>?
    private var lastPoll: ContinuousClock.Instant?
    /// Something failed for the whole drive, so iOS may be holding back until told otherwise.
    private var troubled = false

    /// How often to check while the extension is running.
    private static let interval: Duration = .seconds(60)
    /// A request for changes this soon after a check uses what that check found.
    private static let minimumGap: Duration = .seconds(20)

    init(connector: Connector, domain: NSFileProviderDomain, notes: DriveNotes) {
        self.connector = connector
        self.domain = domain
        self.notes = notes
    }

    /// Starts checking every minute, if that isn't already happening.
    func keepFresh() {
        guard loop == nil else { return }
        loop = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.interval)
                if Task.isCancelled { return }
                if await pollIfDue() {
                    signal()
                }
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        polling?.cancel()
    }

    /// Checks the folders that are due, unless that was just done. A check that fails, such as
    /// with no network, changes nothing: what's known stays, and the next one tries again. A
    /// database that was recovered is finished here first, since nothing else on the iPhone can.
    /// - Returns: Whether anything changed.
    @discardableResult
    func pollIfDue() async -> Bool {
        if let polling {
            return await polling.value
        }
        if let lastPoll, ContinuousClock.now - lastPoll < Self.minimumGap {
            return false
        }
        let connector = connector
        let task = Task<Bool, Never> {
            let drive: OpenDrive
            do {
                drive = try await connector.open()
            } catch {
                await self.note(error)
                return false
            }
            let recovered = (try? await ReadOnlyRecovery.finishIfNeeded(store: drive.store, syncer: drive.syncer)) ?? false
            let result = await drive.syncer.poll()
            let driveFailure = result.failures.first { ($0 as? RemoteError)?.scope == .connection }
            await self.note(driveFailure)
            return recovered || result.changed
        }
        polling = task
        let changed = await task.value
        polling = nil
        lastPoll = .now
        Footprint.note("check")
        return changed
    }

    /// Notes how the drive is doing. A success after a failure tells iOS to stop holding back,
    /// which it otherwise does until told. "Can't sync" is left alone: that's resolved only when
    /// a person presses Try Again in the app, or a refused change would be refused again in a loop.
    func note(_ error: Error?) {
        notes.noteOutcome(error)
        guard error == nil else {
            if let remote = error as? RemoteError, remote.scope == .item { return }
            troubled = true
            return
        }
        guard troubled else { return }
        troubled = false
        Self.resolve(in: domain)
    }

    /// Tells iOS the errors that hold back a whole drive are over.
    static func resolve(in domain: NSFileProviderDomain) {
        guard let manager = NSFileProviderManager(for: domain) else { return }
        for code in [NSFileProviderError.Code.serverUnreachable, .notAuthenticated] {
            manager.signalErrorResolved(NSFileProviderError(code)) { _ in }
        }
    }

    private func signal() {
        NSFileProviderManager(for: domain)?.signalEnumerator(for: .workingSet) { _ in }
    }
}

/// What a person needs to know about this drive, left where the app can show it. Only the
/// extension writes these notes, atomically, so the app never waits on a lock.
struct DriveNotes: Sendable {
    private let url: URL?

    init(domainIdentifier: String) {
        url = UUID(uuidString: domainIdentifier).flatMap { DriveStore.phoneShared()?.filesNotesURL(for: $0) }
    }

    /// Something another app saved here, which a read-only drive can't send.
    func keep(id: String, name: String, isNew: Bool) {
        guard let url else { return }
        FilesNotes.update(at: url) { $0.keep(id: id, name: name, isNew: isNew) }
    }

    /// The server's file is back, or the person deleted the copy.
    func forget(id: String) {
        guard let url else { return }
        FilesNotes.update(at: url) { $0.forget(id: id) }
    }

    func noteOutcome(_ error: Error?) {
        guard let url, case .some(let problem) = FilesNotes.problem(after: error) else { return }
        FilesNotes.update(at: url) { $0.problem = problem }
    }
}
