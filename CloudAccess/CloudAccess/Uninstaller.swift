// Apache 2 license - developer@infinitecontext.com

import AppKit
import CloudCore
import FileProvider
import Observation

/// Uninstalls CloudAccess from this Mac, one checked step at a time: it waits for uploads, removes
/// each drive the protected way, stops every check, deletes what the app keeps here and its
/// passwords, then looks again for anything left. The servers are never touched.
///
/// It belongs to `Drives`, not to a window, so closing About leaves it running.
@MainActor @Observable
final class Uninstaller {
    enum Phase: Equatable {
        /// What will be removed is on screen, and nothing has started.
        case reviewing
        case running
        /// Stopped after a drive, because a person asked. Nothing more goes until Continue.
        case paused
        case failed
        /// Everything but launch at login, which goes at Quit.
        case finished
    }

    private(set) var phase: Phase = .reviewing
    private(set) var run: Uninstall.Run?
    /// Every saved drive, for the page before: ejected and half-done ones too.
    private(set) var drivesToRemove: [Connection] = []
    /// Locations macOS has with no drive behind them.
    private(set) var orphanLocations: [String] = []
    /// Why the page before can't go on, when the drives or locations can't be read.
    private(set) var reviewProblem: String?
    /// The drives and locations have been read, or failed to be.
    private(set) var hasReviewed = false
    /// A drive is leaving Finder now. The window can't close for those few seconds.
    private(set) var isRemovingDrive = false
    /// Quit couldn't turn launch at login off.
    private(set) var loginItemLeft = false
    private var stopsAfterThisDrive = false
    private var task: Task<Void, Never>?

    private unowned let drives: Drives
    private let store: DriveStore?

    init(drives: Drives, store: DriveStore?) {
        self.drives = drives
        self.store = store
    }

    var hasEncryptedDrives: Bool {
        drivesToRemove.contains(where: \.isEncrypted)
    }

    /// Cancel leaves everything as it was, so it's only offered until something is removed.
    var canCancel: Bool {
        !(run?.hasChangedAnything ?? false)
    }

    /// Stopping, and going back to using the app, works until the checks have stopped.
    var canStopUninstalling: Bool {
        run?.state(of: .stopBackgroundWork) == .pending
    }

    // MARK: The page before

    /// Reads what will be removed. Nothing changes.
    func review() async {
        reviewProblem = nil
        defer { hasReviewed = true }
        do {
            drivesToRemove = try drives.everySavedDrive()
        } catch {
            reviewProblem = Uninstall.Line.cantReadDrives(error).shown
            return
        }
        do {
            let domains = try await NSFileProviderManager.domains()
            orphanLocations = Uninstall.orphanLocations(
                domains: Set(domains.map(\.identifier.rawValue)), drives: drivesToRemove)
        } catch {
            reviewProblem = Uninstall.Line.cantListLocations(error, .mac).shown
        }
    }

    // MARK: Running

    func start() {
        guard phase == .reviewing, hasReviewed, reviewProblem == nil else { return }
        run = Uninstall.Run(platform: .mac, drives: drivesToRemove, orphanLocations: orphanLocations)
        resume()
    }

    /// Ends a run that removed nothing. The app goes back to working as before.
    func cancel() {
        guard canCancel else { return }
        task?.cancel()
        drives.endUninstall()
    }

    func stopAfterThisDrive() {
        stopsAfterThisDrive = true
    }

    func continueRun() {
        guard phase == .paused else { return }
        resume()
    }

    func tryAgain() {
        guard phase == .failed else { return }
        run?.tryAgain()
        resume()
    }

    /// Leaves the uninstall where it is, with the drives not yet removed still working.
    func stopUninstalling() {
        guard canStopUninstalling, phase != .running else { return }
        drives.endUninstall()
    }

    private func resume() {
        stopsAfterThisDrive = false
        phase = .running
        task = Task { await proceed() }
    }

    private func proceed() async {
        while let step = run?.next, step != .turnOffLaunchAtLogin {
            guard !Task.isCancelled else { return }
            await perform(step)
            guard let run else { return }
            if run.failedStep != nil {
                phase = .failed
                return
            }
            // Only a cancelled wait ends without passing or failing.
            guard run.state(of: step).isPassed else { return }
            if case .removeDrive = step, stopsAfterThisDrive, run.next != .turnOffLaunchAtLogin {
                phase = .paused
                return
            }
        }
        phase = .finished
    }

    private func perform(_ step: Uninstall.Step) async {
        switch step {
        case .checkFirst: await checkFirst()
        case .waitForUploads: await waitForUploads()
        case .removeDrive(let id, _): await removeDrive(id, step: step)
        case .removeOrphanLocation(let identifier): await removeOrphan(identifier, step: step)
        case .stopBackgroundWork: await stopBackgroundWork()
        case .deleteLocalData: await deleteLocalData()
        case .deletePasswords: deletePasswords()
        case .confirmNothingLeft: await confirmNothingLeft()
        case .turnOffLaunchAtLogin: break
        }
    }

    // MARK: Steps

    private func checkFirst() async {
        run?.begin(.checkFirst)
        let saved: [Connection]
        do {
            saved = try drives.everySavedDrive()
        } catch {
            run?.fail(.checkFirst, reason: .cantReadDrives(error), leftAs: .nothingChanged(.mac))
            return
        }
        do {
            _ = try await NSFileProviderManager.domains()
        } catch {
            run?.fail(.checkFirst, reason: .cantListLocations(error, .mac), leftAs: .nothingChanged(.mac))
            return
        }
        run?.finish(.checkFirst, leftovers: [], note: .found(drives: saved.count), leftAs: .nothingChanged(.mac))
    }

    /// Passes only after two readings in a row find nothing to send, with macOS asked again in
    /// between, so a save made a moment ago isn't missed.
    private func waitForUploads() async {
        run?.begin(.waitForUploads)
        var emptyReadings = 0
        while !Task.isCancelled {
            await drives.refreshAllPending()
            let mounted = drives.connections.filter(\.isMounted)
            let left = mounted.reduce(0) { $0 + drives.unsentCount(of: $1) }
            if left == 0 {
                emptyReadings += 1
                if emptyReadings >= 2 {
                    run?.waiting(filesLeft: 0)
                    return
                }
            } else {
                emptyReadings = 0
                let holds = mounted.compactMap { connection in
                    drives.hold(on: connection).map { Uninstall.Line.hold($0, drive: connection.displayName) }
                }
                run?.waiting(filesLeft: left, holds: holds)
            }
            try? await Task.sleep(for: .seconds(3))
        }
    }

    /// The same removal as a drive's own Remove button, then a look at what macOS, the drive list,
    /// the Keychain and the drive's folder still have of it.
    private func removeDrive(_ id: UUID, step: Uninstall.Step) async {
        guard let store else {
            run?.fail(step, reason: .cantReadDrives(DriveStore.StoreError.noSharedFolder), leftAs: .driveStillThere(.mac))
            return
        }
        isRemovingDrive = true
        defer { isRemovingDrive = false }
        run?.begin(step)
        var keptFiles = false
        do {
            // A drive a person removed from its details while this waited is already gone.
            if let connection = try drives.everySavedDrive().first(where: { $0.id == id }) {
                if let kept = try await drives.remove(connection) {
                    run?.keep(filesAt: kept)
                    keptFiles = true
                }
            }
        } catch {
            let leftAs: Uninstall.Line = await hasLocation(id.uuidString) == false
                ? .driveHalfRemoved(.mac) : .driveStillThere(.mac)
            run?.fail(step, reason: .refused(error, .mac), leftAs: leftAs)
            return
        }
        let domains: [NSFileProviderDomain]
        do {
            domains = try await NSFileProviderManager.domains()
        } catch {
            run?.fail(step, reason: .cantListLocations(error, .mac), leftAs: .driveHalfRemoved(.mac))
            return
        }
        var leftovers: [Uninstall.Leftover] = []
        if domains.contains(where: { $0.identifier.rawValue == id.uuidString }) {
            leftovers.append(.location(id.uuidString))
        }
        // A list that can't be read may still hold the drive.
        if (try? store.connections())?.contains(where: { $0.id == id }) != false {
            leftovers.append(.record)
        }
        if !store.hasNoPassword(for: id) {
            leftovers.append(.password)
        }
        leftovers += store.databaseFiles(for: id).map(Uninstall.Leftover.file)
        let leftAs: Uninstall.Line = leftovers.contains(.location(id.uuidString))
            ? .driveStillThere(.mac) : .driveHalfRemoved(.mac)
        run?.finish(
            step, leftovers: leftovers, note: keptFiles ? .removedKeepingFiles : .removed(.mac), leftAs: leftAs)
    }

    private func removeOrphan(_ identifier: String, step: Uninstall.Step) async {
        isRemovingDrive = true
        defer { isRemovingDrive = false }
        run?.begin(step)
        do {
            if let kept = try await drives.removeOrphanLocation(identifier) {
                run?.keep(filesAt: kept)
            }
        } catch {
            run?.fail(step, reason: .refused(error, .mac), leftAs: .locationStillThere(.mac))
            return
        }
        let stillThere = await hasLocation(identifier)
        run?.finish(
            step, leftovers: stillThere == false ? [] : [.location(identifier)], note: .locationRemoved,
            leftAs: .locationStillThere(.mac))
    }

    private func stopBackgroundWork() async {
        run?.begin(.stopBackgroundWork)
        if await drives.stopForUninstall() {
            run?.finish(.stopBackgroundWork, leftovers: [], note: .stopped, leftAs: .dataStillHere(.mac))
        } else {
            run?.fail(.stopBackgroundWork, reason: .didNotStop, leftAs: .dataStillHere(.mac))
        }
    }

    private func deleteLocalData() async {
        guard let store else {
            run?.fail(.deleteLocalData, reason: .cantReadDrives(DriveStore.StoreError.noSharedFolder), leftAs: .itemsLeft(.mac))
            return
        }
        run?.begin(.deleteLocalData)
        // The list of kept files is deleted with the rest, and it's the only record of where
        // macOS put them.
        for files in ((try? store.preservedFiles()) ?? []) + drives.preservedFiles {
            run?.keep(filesAt: files.path)
        }
        // Nothing in this process may write a new log once it's gone. A line already on its way
        // gets a moment to land first.
        Diagnostics.silence()
        try? await Task.sleep(for: .milliseconds(500))
        var deleted = store.deleteEverything().deleted
        if let id = Bundle.main.bundleIdentifier, UserDefaults.standard.persistentDomain(forName: id) != nil {
            UserDefaults.standard.removePersistentDomain(forName: id)
            deleted += 1
        }
        for item in Uninstall.temporaryItems(in: FileManager.default.temporaryDirectory) {
            if (try? FileManager.default.removeItem(at: item)) != nil {
                deleted += 1
            }
        }
        run?.finish(.deleteLocalData, leftovers: dataLeft(store), note: .deleted(items: deleted), leftAs: .itemsLeft(.mac))
    }

    private func deletePasswords() {
        guard let store else {
            run?.fail(.deletePasswords, reason: .cantReadDrives(DriveStore.StoreError.noSharedFolder), leftAs: .passwordsLeft)
            return
        }
        run?.begin(.deletePasswords)
        do {
            let before = try store.passwordsLeft()
            try store.deleteAllPasswords()
            let left = try store.passwordsLeft()
            run?.finish(
                .deletePasswords, leftovers: left > 0 ? [.passwords] : [], note: .passwordsDeleted(before - left),
                leftAs: .passwordsLeft)
        } catch DriveStore.StoreError.keychain(let status) {
            run?.fail(.deletePasswords, reason: .keychain(status), leftAs: .passwordsLeft)
        } catch {
            run?.fail(.deletePasswords, reason: .refused(error, .mac), leftAs: .passwordsLeft)
        }
    }

    /// Every check again, together: locations, drives, passwords and files.
    private func confirmNothingLeft() async {
        guard let store else {
            run?.fail(.confirmNothingLeft, reason: .cantReadDrives(DriveStore.StoreError.noSharedFolder), leftAs: .itemsLeft(.mac))
            return
        }
        run?.begin(.confirmNothingLeft)
        let domains: [NSFileProviderDomain]
        do {
            domains = try await NSFileProviderManager.domains()
        } catch {
            run?.fail(.confirmNothingLeft, reason: .cantListLocations(error, .mac), leftAs: .itemsLeft(.mac))
            return
        }
        var leftovers = domains.map { Uninstall.Leftover.location($0.identifier.rawValue) }
        if !((try? store.connections())?.isEmpty ?? false) {
            leftovers.append(.record)
        }
        if (try? store.passwordsLeft()) != 0 {
            leftovers.append(.passwords)
        }
        leftovers += dataLeft(store)
        run?.finish(.confirmNothingLeft, leftovers: leftovers, note: .nothingLeft(.mac), leftAs: .itemsLeft(.mac))
    }

    private func dataLeft(_ store: DriveStore) -> [Uninstall.Leftover] {
        var left = store.whatsLeft()
        if let id = Bundle.main.bundleIdentifier, !(UserDefaults.standard.persistentDomain(forName: id)?.isEmpty ?? true) {
            left.append("\(id).plist")
        }
        left += Uninstall.temporaryItems(in: FileManager.default.temporaryDirectory).map(\.path)
        return left.map(Uninstall.Leftover.file)
    }

    /// Whether macOS lists a location, or nil if it won't say.
    private func hasLocation(_ identifier: String) async -> Bool? {
        guard let domains = try? await NSFileProviderManager.domains() else { return nil }
        return domains.contains { $0.identifier.rawValue == identifier }
    }

    // MARK: The end

    /// Turns launch at login off and quits. If it can't be turned off, the app stays open and
    /// says so, with the way to turn it off by hand.
    func quit() {
        guard phase == .finished else { return }
        run?.begin(.turnOffLaunchAtLogin)
        if !LoginAgent.uninstallAndQuit() {
            loginItemLeft = true
            run?.finish(
                .turnOffLaunchAtLogin, leftovers: [.loginItem], leftAs: .itemsLeft(.mac))
        }
    }

    /// Quits with launch at login left for a person to turn off in System Settings.
    func quitLeavingLoginItem() {
        LoginAgent.quit()
    }

    func showAppInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}
