// Apache 2 license - developer@infinitecontext.com

import AppKit
import CloudCore
import FileProvider
#if DEBUG
import notify
#endif
import Observation
import os
import RemoteEngine
import SyncCore

#if DEBUG
/// `NSLog` only reaches a file when a test starts the app itself. This reaches the system log
/// when the app was started the normal way, so a running copy can be checked as it is.
let testReports = Logger(subsystem: "com.infinitecontext.CloudAccess", category: "test")
#endif

/// Something the panel asks Settings to open for a drive.
struct DriveRequest: Identifiable, Equatable {
    enum Sheet: String {
        case settings
        case deletedFiles
        case information
        case code
    }

    let driveID: UUID
    let sheet: Sheet

    var id: String {
        "\(driveID)-\(sheet.rawValue)"
    }
}

/// A file macOS hasn't finished syncing, and what's known about why.
struct PendingFile: Identifiable, Equatable, Sendable {
    enum State: Equatable, Sendable {
        /// Nothing's wrong, as far as anyone has said.
        case waiting
        /// It failed, and macOS is going to try it again.
        case failing(SyncAttempt)
        /// macOS has a problem with it that never reached this app.
        case refused(String)
        /// It's stopped until a person helps.
        case held
    }

    let id: String
    let name: String
    let folder: RemotePath?
    let size: Int64?
    let state: State
}

/// Everything the Information page shows. It's read again every second while the page is open.
struct DriveReport: Equatable {
    var transfers: [SyncTransfer] = []
    var failures: [SyncFailure] = []
    /// The folder each failed file is in, by the failure's ID.
    var failedFolders: [String: RemotePath] = [:]
    var pending: [PendingFile] = []
    var recent: [SyncActivity] = []
    var totals = SyncTotals()
    var lastChecked: Date?
    var isBeingChecked = false
}

/// The line under the drives, which opens the Information page.
struct ActivityLine {
    let connection: Connection
    let title: String
    let summary: String
    let isStuck: Bool
}

/// The app's list of drives, registering them with macOS, and checking them for changes.
@MainActor @Observable
final class Drives {
    enum DriveError: LocalizedError {
        case duplicateName
        case duplicateDrive
        #if DEBUG
        case notATestFolder
        #endif
        case noSharedFolder
        case unsafeNeedsSFTP
        case insecureNotAllowed
        case uninstalling

        /// Shown to a person, so it's in the language shown. Diagnostics record the case's name.
        var errorDescription: String? {
            switch self {
            case .uninstalling:
                return String(localized: "CloudAccess is being uninstalled, so drives can't be added or changed.")
            case .unsafeNeedsSFTP:
                return DriveEdit.unsafeNeedsSFTP
            case .insecureNotAllowed:
                return String(localized: "This drive uses plain http, which sends its password readably. Allow that first.")
            case .duplicateName:
                return DriveEdit.Clash.name.reason
            case .duplicateDrive:
                return DriveEdit.Clash.place.reason
            #if DEBUG
            case .notATestFolder:
                // A test guard, so it stays English.
                return "This test build only connects to a folder named \(Connection.testFolderName)."
            #endif
            case .noSharedFolder:
                return String(localized: "The app's shared folder isn't available.")
            }
        }
    }

    private struct OpenDrive {
        let engine: RemoteEngine
        let syncer: Syncer
        let state: SyncStore
    }

    /// What the panel shows for a drive.
    enum Status: Equatable {
        case connected
        case syncing(Int)
        /// Files are waiting, and nothing is moving them.
        case notMoving(Int)
        /// Files that are stopped until a person helps.
        case needsAttention(Int)
        case offline
        case needsEnabling
        case unmounted

        /// For diagnostics, which stay English.
        var label: String? {
            switch self {
            case .connected: nil
            case .syncing(let count): "syncing \(count)"
            case .notMoving(let count): count == 1 ? "1 upload paused" : "\(count) uploads paused"
            case .needsAttention(let count):
                count == 1 ? "1 file needs attention" : "\(count) files need attention"
            case .offline: "offline"
            case .needsEnabling: "turn on in System Settings"
            case .unmounted: "ejected"
            }
        }

        /// The same, in the language shown, for the screen.
        var shownLabel: String? {
            switch self {
            case .connected: nil
            case .syncing(let count): String(localized: "syncing \(count)")
            case .notMoving(let count): String(localized: "\(count) uploads paused")
            case .needsAttention(let count): String(localized: "\(count) files need attention")
            case .offline: String(localized: "offline")
            case .needsEnabling: String(localized: "turn on in System Settings")
            case .unmounted: String(localized: "ejected")
            }
        }
    }

    /// The dot beside a drive: mounted, mounted with a problem, or not mounted. Its description
    /// is what VoiceOver says, in the language shown.
    enum Light: CustomStringConvertible {
        case green
        case yellow
        case red

        var description: String {
            switch self {
            case .green: String(localized: "Mounted")
            case .yellow: String(localized: "Problem")
            case .red: String(localized: "Not mounted")
            }
        }
    }

    private(set) var connections: [Connection] = []
    /// Drives with a whole-connection problem. A failed file never puts a drive here.
    private(set) var offline: Set<UUID> = []
    /// Why each offline drive can't reach its server, as far as checking proved it.
    let checks = ConnectionChecks(device: .mac)
    /// Whether this Mac has a network at all, straight from the system.
    private(set) var isNetworkUp = true
    /// Drives a person asked to check again, while that runs. Each drive's button turns on its own.
    private(set) var checkingAgain: Set<UUID> = []
    /// Launch at login, kept fresh, so its warning goes soon after a person allows it.
    private(set) var loginStatus = LoginAgent.status
    /// Reads both permissions again every few seconds while either still waits for a person.
    @ObservationIgnored private var permissionWatch: Task<Void, Never>?
    /// A problem reading the saved drives, which must never look like having no drives.
    private(set) var storeProblem: String?
    /// Domains macOS has registered that no saved drive matches. They're kept, not removed.
    private(set) var unknownDomains: [String] = []
    /// Files macOS kept when a drive with unsent changes was removed.
    private(set) var preservedFiles: [DriveStore.PreservedFiles] = []
    /// Drives macOS has registered but the person hasn't turned on yet.
    private(set) var notEnabled: Set<UUID> = []
    /// How much each drive has on this Mac.
    private(set) var cachedBytes: [UUID: Int64] = [:]
    /// Files macOS lists as not yet synced, by name. This is the truth about what's waiting. macOS's
    /// upload progress can't name a file, and only tracks what's under way.
    private(set) var pending: [UUID: [PendingFile]] = [:]
    /// How many of those have nothing known to be wrong with them.
    private(set) var waiting: [UUID: Int] = [:]
    /// How many of those keep failing, and are being tried again.
    private(set) var retrying: [UUID: Int] = [:]
    /// Drives with files waiting and no sign of anything moving them.
    private(set) var stalled: Set<UUID> = []
    /// How many files each drive is downloading, which only matters for showing activity.
    private(set) var downloading: [UUID: Int] = [:]
    /// True while Show mounts in Finder is checking the drives.
    private(set) var isShowingMounts = false
    /// Files that couldn't sync, shown in the panel until they succeed.
    private(set) var failures: [UUID: [SyncFailure]] = [:]
    /// Places macOS named that couldn't be written down yet. It only names them once.
    private var unsavedPreserved: [DriveStore.PreservedFiles] = []
    /// Waits here until Settings is on screen to open it.
    var request: DriveRequest?
    /// The panel's + button, waiting for Settings the same way.
    var wantsAddForm = false
    /// Why a drive can't connect, when waiting won't fix it.
    private(set) var problems: [UUID: RemoteError] = [:]
    /// Drives whose SFTP server now offers a different key, until someone reviews it.
    private(set) var changedHostKeys: Set<UUID> = []
    /// How much is left to upload, from macOS's progress, which doesn't always know.
    private var waitingBytes: [UUID: Int64] = [:]
    /// Whether the disk is below a drive's reserve. Files waiting to upload can't be removed to
    /// make room, so that's worth saying while they wait.
    private var isLowOnSpace = false
    /// What macOS's upload progress counts, which is only a hint that the list needs reading.
    private var reportedUploads: [UUID: Int] = [:]
    private var lastChecked: [UUID: Date] = [:]
    /// The last proof of movement: a transfer reporting, a file finishing, the list changing, or
    /// macOS seeing upload bytes move.
    private var lastMoved: [UUID: Date] = [:]
    private var lastFinished: [UUID: Int] = [:]
    private var lastWaiting: [UUID: Set<String>] = [:]
    private var lastDownloaded: [UUID: (bytes: Int64, at: Date)] = [:]
    /// When macOS last saw upload bytes move. It's a second proof beside our own records, so
    /// bytes being sent are never called stopped.
    private var lastUploaded: [UUID: (bytes: Int64, at: Date)] = [:]
    private var readingPending = Set<UUID>()
    private var transferTicks = 0
    @ObservationIgnored private var lastLogged: [UUID: String] = [:]
    /// The uninstall under way, if there is one. While it runs nothing is added, mounted or edited.
    private(set) var uninstaller: Uninstaller?
    /// Set when an uninstall has stopped every check, for good. Nothing may then open a drive's
    /// database, because that would create it again after it's deleted.
    private var isStopped = false

    var isUninstalling: Bool {
        uninstaller != nil
    }

    /// The uninstall under way, or a new one.
    func beginUninstall() -> Uninstaller {
        if let uninstaller {
            return uninstaller
        }
        let made = Uninstaller(drives: self, store: store)
        uninstaller = made
        return made
    }

    /// Drops an uninstall that changed nothing, or stopped before the checks did, so the app goes
    /// back to working as it was.
    func endUninstall() {
        guard !isStopped else { return }
        uninstaller = nil
        reload()
    }

    var needsEnabling: Bool {
        !notEnabled.isEmpty
    }

    /// Drives the animated sign, in the menu bar and on a drive's row.
    var isSyncing: Bool {
        isShowingMounts || connections.contains(where: isTransferring)
    }

    /// Only true with proof, so the sign never turns over files that aren't going anywhere. Nothing
    /// moves while a drive can't be reached, so that shows as offline, not syncing.
    func isTransferring(_ connection: Connection) -> Bool {
        guard !offline.contains(connection.id) else { return false }
        let isUploading = (waiting[connection.id] ?? 0) > 0 && !stalled.contains(connection.id)
        return isUploading || (downloading[connection.id] ?? 0) > 0
    }

    /// Whether a drive has files stuck, or stopped until a person helps.
    func needsHelp(on connection: Connection) -> Bool {
        switch status(of: connection) {
        case .notMoving, .needsAttention:
            return true
        case .syncing, .connected:
            return !(failures[connection.id] ?? []).isEmpty
        case .offline, .needsEnabling, .unmounted:
            return false
        }
    }

    var needsHelp: Bool {
        connections.contains(where: needsHelp(on:))
    }

    /// The drive worth opening when someone asks what's going on: the worst off, then the busiest.
    var driveToReport: Connection? {
        connections.first(where: needsHelp(on:))
            ?? offlineDrives.first
            ?? connections.first(where: isTransferring)
            ?? connections.first(where: \.isMounted)
            ?? connections.first
    }

    /// Files that haven't reached the server, for warning before they're left behind. It's the
    /// higher of the two counts, because saying too many costs far less here than too few.
    func unsentCount(of connection: Connection) -> Int {
        max(
            pending[connection.id]?.count ?? 0, reportedUploads[connection.id] ?? 0,
            failures[connection.id]?.count ?? 0)
    }

    /// What the whole app shows about connections. A drive that fails because of its own server
    /// says so only in its own places. Only a problem with this Mac is shown app-wide.
    var appWideWarning: AppWideWarning {
        AppWideWarning.from(mounted.filter { offline.contains($0.id) }.compactMap { checks.findings[$0.id] })
    }

    /// Drives that can't connect because Tailscale is off on this Mac, which a check proved. A
    /// tailnet address alone proves nothing: the server may be the one that's off.
    var drivesWithTailscaleOff: [Connection] {
        connections.filter { offline.contains($0.id) && checks.findings[$0.id]?.kind == .tailscaleOff }
    }

    /// Each problem with this Mac that some drives feel, for Settings, which lists them all.
    var deviceProblems: [AppWideWarning] {
        AppWideWarning.deviceProblems(in: offlineDrives.compactMap { checks.findings[$0.id] })
    }

    /// The Local Network list in Privacy & Security, where CloudAccess is allowed to reach
    /// devices on this network. macOS asks once, and a person may have said no.
    func openLocalNetworkSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Some drives connect and some don't, each for its own server's reasons.
    var isPartlyConnected: Bool {
        !offline.isEmpty && !hasConnectionProblem
    }

    /// Whether another drive, on another server, connected at the last poll. That's evidence this
    /// Mac's network works.
    private func connectsToAnotherServer(than connection: Connection) -> Bool {
        let target = ConnectionCheck.Target(connection)
        return mounted.contains { !offline.contains($0.id) && ConnectionCheck.Target($0) != target }
    }

    /// Check Again: drops each drive's connection, checks why it can't connect, then polls. The
    /// poll every 30 seconds keeps checking without it.
    func checkAgain(_ chosen: [Connection]) async {
        let fresh = chosen.filter { !checkingAgain.contains($0.id) }
        guard !fresh.isEmpty else { return }
        let ids = Set(fresh.map(\.id))
        checkingAgain.formUnion(ids)
        defer { checkingAgain.subtract(ids) }
        for connection in fresh {
            open[connection.id] = nil
        }
        await checks.check(
            fresh.filter { offline.contains($0.id) }, byAPerson: true,
            otherServersOnline: { [weak self] in self?.connectsToAnotherServer(than: $0) ?? false })
        await pollOnce(force: true)
    }

    /// Check Again is running for some drive.
    var isCheckingAgain: Bool {
        !checkingAgain.isEmpty
    }

    /// Check Again is running for this drive, or a check of it is.
    func isChecking(_ connection: Connection) -> Bool {
        checkingAgain.contains(connection.id) || checks.checking.contains(connection.id)
    }

    /// The drives that can't connect now.
    var offlineDrives: [Connection] {
        mounted.filter { offline.contains($0.id) }
    }

    /// The App Store and standalone builds have different identifiers.
    private var tailscaleApp: URL? {
        ["io.tailscale.ipn.macos", "io.tailscale.ipn.macsys"].lazy
            .compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
            .first
    }

    var hasTailscale: Bool {
        tailscaleApp != nil
    }

    /// No app can turn on another app's VPN, so opening it is as far as this can go. The drive
    /// comes back by itself once it's on: the network change checks it straight away.
    func openTailscale() {
        guard let tailscaleApp else { return }
        NSWorkspace.shared.openApplication(at: tailscaleApp, configuration: NSWorkspace.OpenConfiguration())
    }

    /// A drive's state in a few words, for its row, in the language shown.
    func statusLabel(of connection: Connection) -> String? {
        let state = status(of: connection)
        if state == .offline, let label = problems[connection.id]?.attentionLabel {
            return label
        }
        if state == .offline {
            if checks.isSettling {
                return String(localized: "reconnecting")
            }
            if let finding = checks.findings[connection.id] {
                let reason = finding.shortLabel
                return String(localized: "offline, \(reason)")
            }
            if checks.checking.contains(connection.id) {
                let reason = String(localized: "checking…")
                return String(localized: "offline, \(reason)")
            }
        }
        return state.shownLabel
    }

    /// What's wrong with a drive that isn't connected, as far as checking proved it. Saves only
    /// wait out an outage: with a wrong password or a retired vault, they wait for a person.
    func offlineMessage(of connection: Connection) -> String {
        if let problem = problems[connection.id], problem.attentionLabel != nil {
            let reason = problem.localizedDescription
            return String(localized: "\(reason) Files on this Mac are still available, and nothing uploads until this is fixed.")
        }
        if checks.isSettling {
            return String(localized: "Reconnecting…")
        }
        if let finding = checks.findings[connection.id] {
            let reason = finding.sentence
            return String(localized: "\(reason) Files on this Mac are still available, and saves upload when the connection returns.")
        }
        return String(localized: "Not connected. Files on this Mac are still available, and saves upload when the connection returns.")
    }

    /// The first drive a person has to act on. A changed host key has its own card.
    var driveNeedingAttention: (connection: Connection, label: String)? {
        for connection in connections where !changedHostKeys.contains(connection.id) {
            if let label = problems[connection.id]?.attentionLabel {
                return (connection, label)
            }
        }
        return nil
    }

    var allFailures: [SyncFailure] {
        connections.flatMap { failures[$0.id] ?? [] }
    }

    /// A short line for the panel, only while there's something to say. "Uploading" is only ever
    /// said while something is moving.
    var activityLine: ActivityLine? {
        if let stuck = connections.first(where: needsHelp(on:)) {
            let label = statusLabel(of: stuck) ?? String(localized: "needs attention")
            return ActivityLine(
                connection: stuck, title: String(localized: "Attention"),
                summary: "\(stuck.displayName): \(label)", isStuck: true)
        }
        let uploading = connections.filter { isTransferring($0) && (waiting[$0.id] ?? 0) > 0 }
        guard let first = uploading.first else { return nil }
        let count = uploading.reduce(0) { $0 + (waiting[$1.id] ?? 0) }
        let left = uploading.reduce(Int64(0)) { $0.addingReportingOverflow(waitingBytes[$1.id] ?? 0).partialValue }
        var summary: String
        if left > 0 {
            let bytes = left.formatted(.byteCount(style: .file))
            summary = String(localized: "\(count) files, about \(bytes) to go")
        } else {
            summary = String(localized: "\(count) files")
        }
        // Saves can't be held back, because macOS owns them, so this can only say so.
        if isLowOnSpace {
            summary = String(localized: "\(summary). Your Mac is low on space. Files stay on it until they're uploaded.")
        }
        return ActivityLine(connection: first, title: String(localized: "Uploading"), summary: summary, isStuck: false)
    }

    /// What the side panel says about a drive, above its actions.
    func details(of connection: Connection) -> [ConnectionSummary.Detail] {
        let state = statusLabel(of: connection) ?? String(localized: "mounted")
        var details = [
            ConnectionSummary.Detail(
                key: String(localized: "Status"), value: state.prefix(1).uppercased() + state.dropFirst())
        ]
        // The translated form: the English one is for diagnostics.
        details += ConnectionSummary.shownDetails(of: connection)
        if let cached = cachedBytes[connection.id] {
            details.append(.init(key: String(localized: "On this Mac"), value: cached.formatted(.byteCount(style: .file))))
        }
        return details
    }

    func light(of connection: Connection) -> Light {
        switch status(of: connection) {
        case .unmounted:
            return .red
        case .offline, .needsEnabling, .notMoving, .needsAttention:
            return .yellow
        case .connected, .syncing:
            return (failures[connection.id] ?? []).isEmpty ? .green : .yellow
        }
    }

    /// Only mounted drives are checked. An ejected one has no domain to keep up to date.
    private var mounted: [Connection] {
        connections.filter(\.isMounted)
    }

    func status(of connection: Connection) -> Status {
        guard connection.isMounted else { return .unmounted }
        if notEnabled.contains(connection.id) { return .needsEnabling }
        if offline.contains(connection.id) { return .offline }
        let count = waiting[connection.id] ?? 0
        if count > 0, isTransferring(connection) { return .syncing(count) }
        let failed = (failures[connection.id] ?? []).count
        if failed > 0 { return .needsAttention(failed) }
        let notMoving = count + (retrying[connection.id] ?? 0)
        return notMoving > 0 ? .notMoving(notMoving) : .connected
    }

    /// Nothing can connect: no network, or the drive list itself can't be read. A server that's
    /// off is only its own drives' problem, and never turns the whole app gray.
    var hasConnectionProblem: Bool {
        (!isNetworkUp && !mounted.isEmpty) || appWideWarning.stopsEveryDrive || storeProblem != nil
    }

    private let store: DriveStore?
    private var open: [UUID: OpenDrive] = [:]
    /// Each drive's database, which stays usable when the server doesn't.
    private var states: [UUID: SyncStore] = [:]
    private var offlineSince: [UUID: Date] = [:]
    private var network: NetworkWatcher?
    private var memory: MemoryWatcher?
    /// How long a poll waits for macOS. It normally answers at once, and a poll that gives up
    /// tries again next time.
    private static let macOSLimit = Duration.seconds(120)
    /// More folders than this on disk are left to macOS's own import, which gets there in time.
    private static let importFolderLimit = 5_000
    private var hurrying = Set<UUID>()

    private var isPolling = false
    private var pollAgain = false
    private var lastHousekeeping: [UUID: Date] = [:]
    private var lastReconcile: [UUID: Date] = [:]
    @ObservationIgnored private var lastTrashPass: [UUID: Date] = [:]
    @ObservationIgnored private var trashRetention: [UUID: Int] = [:]
    @ObservationIgnored private var clearingTrash = Set<UUID>()
    @ObservationIgnored private var uploads: [UUID: Progress] = [:]
    @ObservationIgnored private var downloads: [UUID: Progress] = [:]
    private var transfersTask: Task<Void, Never>?
    private var pollingTask: Task<Void, Never>?

    /// macOS's list can be long, and only the start of it is ever on screen.
    private static let pendingLimit = 500
    /// How long files can wait with no sign of movement before the app stops calling it syncing.
    /// macOS pauses by itself at times, such as while it takes in a large copy, and that's not
    /// worth an alert.
    static let stallLimit: TimeInterval = 300
    /// A download's bytes stop rising when it's over, whatever macOS's progress still says.
    private static let downloadSilence: TimeInterval = 60
    /// Numbers only, never a name, so this can stay in a release build.
    private static let log = Logger(subsystem: "com.infinitecontext.CloudAccess", category: "app")

    private static let pollInterval: Duration = .seconds(30)
    private static let housekeepingInterval: TimeInterval = 86_400
    private static let reconcileInterval: TimeInterval = 300
    /// A short drop shouldn't send every file past macOS twice, so badges wait this long.
    private static let unavailableDelay: TimeInterval = 60
    /// Often enough for the sync sign to feel live, and reading these costs almost nothing.
    private static let transfersInterval: Duration = .seconds(2)
    /// A check can finish in a moment, and a sign that only flashes says nothing.
    private static let shortestSyncSign: Duration = .seconds(1)

    init() {
        store = try? DriveStore.shared()
        checks.log = { [store] line in store?.diagnostics.record(line) }
        reload()
        memory = MemoryWatcher { [weak self] level in
            self?.memoryLevelChanged(to: level)
        }
        watchForSecondCopies()
        watchConnectivity()
        watchPermissions()
        transfersTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.transfersInterval)
                self?.updateTransfers()
            }
        }
        #if DEBUG
        runTestHook()
        #endif
        pollingTask = Task { [weak self] in
            await self?.repair()
            while !Task.isCancelled {
                await self?.pollOnce()
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    private func reload() {
        guard let store else {
            storeProblem = DriveError.noSharedFolder.localizedDescription
            return
        }
        do {
            connections = try store.connections().filter { $0.lifecycle == .active }
            preservedFiles = ((try? store.preservedFiles()) ?? []) + unsavedPreserved
            storeProblem = nil
        } catch {
            // Keep showing what was loaded, and say so, rather than an empty list.
            let reason = error.localizedDescription
            storeProblem = String(localized: "The saved drives can't be read: \(reason)")
        }
    }

    // MARK: Repair

    /// Finishes whatever a crash interrupted, so a saved drive and its macOS domain agree.
    /// Nothing here removes a domain that has no record.
    private func repair() async {
        guard let store, let saved = try? store.connections(),
              let domains = try? await NSFileProviderManager.domains()
        else { return }
        // An ejected drive has no domain on purpose, so all that can be left is removing it.
        let all = saved.filter { $0.isMounted || $0.lifecycle == .removing }
        let identifiers = Set(domains.map(\.identifier.rawValue))
        let actions = DriveRepair.plan(drives: all.map { ($0.id, $0.lifecycle) }, domains: identifiers)
        var unknown: [String] = []
        for action in actions {
            switch action {
            case .register(let id):
                if let connection = all.first(where: { $0.id == id }) {
                    try? await NSFileProviderManager.add(domain(for: connection))
                }
            case .activate(let id):
                if var connection = all.first(where: { $0.id == id }) {
                    connection.lifecycle = .active
                    try? store.save(connection)
                }
            case .forget(let id):
                try? store.remove(id: id)
            case .finishRemoving(let id):
                if let connection = all.first(where: { $0.id == id }) {
                    try? await finishRemoving(connection)
                }
            case .reportUnknownDomain(let identifier):
                unknown.append(identifier)
            }
        }
        unknownDomains = unknown
        reload()
    }

    // MARK: Polling

    /// Gives memory back, because a small process is a late target when macOS has to end some.
    private func memoryLevelChanged(to level: MemoryWatcher.Level) {
        #if DEBUG
        NSLog("CM_MEMORY: %@", String(describing: level))
        #endif
        switch level {
        case .normal:
            // Polling paused at critical, so catch up now.
            Task { await pollOnce() }
        case .warning, .critical:
            for drive in open.values {
                drive.state.releaseMemory()
            }
            Task { await RemoteEngine.releaseMemory() }
        }
    }

    /// A second copy opened by hand leaves straight away, and asks this one to show itself. And
    /// this copy, if opened by hand, gives way to the agent's copy when that starts.
    private func watchForSecondCopies() {
        LoginAgent.watchForAgentCopy { [weak self] in
            self?.uninstaller != nil
        }
        DistributedNotificationCenter.default().addObserver(
            forName: LoginAgent.showSettingsNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                if let drives = AppDelegate.drives {
                    AppWindows.showSettings(drives: drives)
                }
            }
        }
    }

    /// Losing the network is known straight away, instead of when a request times out, and
    /// having it back, or waking up, checks the drives instead of waiting for the next poll.
    private func watchConnectivity() {
        network = NetworkWatcher { [weak self] isUp in
            Task { @MainActor [weak self] in await self?.networkChanged(isUp: isUp) }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // Nothing moved during the sleep, and that says nothing about the files.
                self?.lastMoved = [:]
                // Interfaces take a moment after waking, so a failure meanwhile isn't judged.
                self?.checks.settle(for: 10)
                Task { await self?.pollOnce() }
            }
        }
    }

    private func networkChanged(isUp: Bool) async {
        store?.diagnostics.record(isUp ? "Network available" : "Network lost")
        isNetworkUp = isUp
        guard !isUp else {
            checks.settle(for: 5)
            await pollOnce()
            return
        }
        offline = Set(mounted.map(\.id))
        for connection in mounted {
            await noteConnection(of: connection, isOffline: true)
        }
        // The check stops at this Mac's own network, so it contacts nothing.
        await checks.check(mounted, byAPerson: false, otherServersOnline: { _ in false })
    }

    /// Tells the extension, through the drive's database, so it can answer Finder at once. After
    /// a while it also marks what can't be opened, so a short drop stays quiet.
    private func noteConnection(of connection: Connection, isOffline: Bool) async {
        guard let state = try? await localState(connection) else { return }
        try? state.setOffline(isOffline)
        var showsUnavailable = false
        if isOffline {
            let since = offlineSince[connection.id] ?? Date()
            offlineSince[connection.id] = since
            showsUnavailable = Date().timeIntervalSince(since) >= Self.unavailableDelay
        } else {
            offlineSince[connection.id] = nil
        }
        if (try? state.setShowsUnavailable(showsUnavailable)) == true {
            try? await signalPendingChanges(of: connection, state: state)
        }
    }

    /// Checks each drive, and tells macOS about anything that changed. Polls never overlap:
    /// one asked for during a poll runs straight after it.
    /// - Parameter force: Checks every listed folder now, instead of those due.
    func pollOnce(force: Bool = false) async {
        guard !isStopped, memory?.level != .critical else { return }
        guard !isPolling else {
            pollAgain = pollAgain || force
            return
        }
        isPolling = true
        defer { isPolling = false }

        // A windowless app can be slowed down when it looks idle, so a poll says it's working.
        let activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep, reason: "Checking drives for changes")
        defer { ProcessInfo.processInfo.endActivity(activity) }

        var forced = force
        repeat {
            pollAgain = false
            await pollDrives(force: forced)
            forced = true
        } while pollAgain
    }

    private func pollDrives(force: Bool) async {
        saveWaitingPreserved()
        var failed = Set<UUID>()
        // Why each drive failed, for the check that explains it once the poll is done.
        var lost: [UUID: Error] = [:]
        for connection in mounted {
            do {
                let drive = try await opened(connection)
                // A real request: a drive that's open can't otherwise tell the server is gone.
                try await drive.engine.checkHealth()
                lastChecked[connection.id] = Date()
                changedHostKeys.remove(connection.id)
                problems[connection.id] = nil
                await pinVaultRevision(of: connection, engine: drive.engine)
                try await rebuildIfNeeded(connection, drive: drive)
                if (try? drive.state.isRecovering()) == true {
                    await clearThrottling(of: connection)
                    hurryImport(of: connection)
                } else if (try? drive.state.takeBusyRetry()) == true {
                    await clearThrottling(of: connection)
                }
                let result = force
                    ? await drive.syncer.poll(recentInterval: 0, otherInterval: 0)
                    : await drive.syncer.poll(
                        recentInterval: connection.settings.recentFolderInterval,
                        otherInterval: connection.settings.otherFolderInterval)
                #if DEBUG
                NSLog(
                    "CM_POLL: %@ checked=%d changed=%d failures=%@", connection.displayName,
                    result.checked, result.changed ? 1 : 0, String(describing: result.failures))
                #endif
                // One failed folder isn't a connection problem, but a lost connection is.
                if let folderError = result.failures.first(where: { ($0 as? RemoteError)?.scope == .connection }) {
                    #if DEBUG
                    NSLog("CM_OFFLINE: %@: a folder couldn't be reached", connection.displayName)
                    #endif
                    failed.insert(connection.id)
                    lost[connection.id] = folderError
                    await noteConnection(of: connection, isOffline: true)
                    continue
                }
                try await signalPendingChanges(of: connection, state: drive.state)
                await reconcile(connection, state: drive.state)
                await removeLocalCopies(of: connection, state: drive.state)
                await houseKeep(connection, drive: drive)
                await forgetFilesThatWentAway(of: connection, state: drive.state)
                updateFigures(for: connection, state: drive.state)
                // Beside the poll, because macOS can take a while, and other drives are waiting.
                Task { await refreshPending(of: connection) }
                // This goes first: macOS retries as soon as its back-off is cleared.
                await noteConnection(of: connection, isOffline: false)
                if offline.contains(connection.id) {
                    store?.diagnostics.record("\(connection.displayName): back online")
                    await clearThrottling(of: connection)
                }
            } catch {
                #if DEBUG
                NSLog("CM_OFFLINE: %@: %@", connection.displayName, String(describing: error))
                #endif
                if !offline.contains(connection.id) {
                    store?.diagnostics.record("\(connection.displayName): offline: \(error)")
                }
                failed.insert(connection.id)
                lost[connection.id] = error
                if let engine = open[connection.id]?.engine {
                    await pinVaultRevision(of: connection, engine: engine)
                }
                open[connection.id] = nil
                if case RemoteError.hostKeyChanged = error {
                    changedHostKeys.insert(connection.id)
                }
                problems[connection.id] = error as? RemoteError
                await noteConnection(of: connection, isOffline: true)
            }
        }
        offline = failed
        checks.keep(only: failed)
        // Beside the poll: each new failure is checked once, and the poll is the recheck.
        checks.noteFailures(
            mounted.compactMap { connection in lost[connection.id].map { (connection, $0) } },
            otherServersOnline: { [weak self] in self?.connectsToAnotherServer(than: $0) ?? false })
        await refreshPermissions()
    }

    /// macOS imports what it holds in the background, and that can wait a long time, with unsent
    /// files sitting in folders it hasn't reached and new ones going unnoticed. A coordinated read
    /// makes it process a folder and its direct children, so this goes down what's on this Mac,
    /// on every poll until macOS says it has finished. It runs beside the poll, because a read
    /// waits for macOS, and polls have every other drive to get to.
    private func hurryImport(of connection: Connection) {
        guard !hurrying.contains(connection.id) else { return }
        hurrying.insert(connection.id)
        Task {
            defer { hurrying.remove(connection.id) }
            guard let root = await location(of: connection) else { return }
            let isClaimed = root.startAccessingSecurityScopedResource()
            defer {
                if isClaimed { root.stopAccessingSecurityScopedResource() }
            }
            let limit = Self.importFolderLimit
            let count = await withCheckedContinuation { finished in
                DispatchQueue.global(qos: .utility).async {
                    let folders = LocalFolders.under(root, limit: limit)
                    for folder in folders {
                        var problem: NSError?
                        NSFileCoordinator(filePresenter: nil).coordinate(
                            readingItemAt: folder, options: [], error: &problem) { _ in }
                    }
                    finished.resume(returning: folders.count)
                }
            }
            #if DEBUG
            NSLog("CM_IMPORT: %@ hurried %d folders", connection.displayName, count)
            #endif
            _ = count
        }
    }

    /// Keeps the highest vault revision seen. Without it, a restart forgets a retired vault, and a
    /// server restored from before that would pass for the real one.
    private func pinVaultRevision(of connection: Connection, engine: RemoteEngine) async {
        guard connection.isEncrypted, let store,
              let seen = try? await engine.seenVaultRevision(), seen > (connection.vaultRevision ?? 0),
              var current = try? store.connection(id: connection.id)
        else { return }
        current.vaultRevision = seen
        try? store.save(current)
        reload()
    }

    /// Finishes a recovery. Every server item has to be known before macOS offers what it holds,
    /// or its items would look new and turn into conflict copies. The flag stays until this has
    /// worked, so an outage part way only means it runs again.
    private func rebuildIfNeeded(_ connection: Connection, drive: OpenDrive) async throws {
        guard (try? drive.state.needsRebuild()) == true else { return }
        store?.diagnostics.record("\(connection.displayName): rebuilding from the server")
        try await drive.syncer.refreshTree()
        // The extension has been telling macOS to wait, and it won't offer anything until told.
        await clearThrottling(of: connection)
        // Before asking, because a small import can finish before the call returns.
        try drive.state.noteImportStarted()
        do {
            try await reimport(connection)
        } catch is TimedOut {
            // That's macOS, not the server, and the flag brings this back on the next poll.
            return
        }
        try drive.state.setNeedsRebuild(false)
    }

    private func updateFigures(for connection: Connection, state: SyncStore) {
        cachedBytes[connection.id] = try? state.localCopiesSize()
        failures[connection.id] = (try? state.failures()) ?? []
    }

    /// macOS updates these objects as it goes, so they're kept rather than asked for each time.
    /// They only hint at what's going on: `refreshPending` says which files are really waiting.
    private func updateTransfers() {
        guard !isStopped else { return }
        func remaining(_ progress: Progress?) -> Int {
            guard let progress else { return 0 }
            return max(0, (progress.fileTotalCount ?? 0) - (progress.fileCompletedCount ?? 0))
        }
        transferTicks += 1
        let now = Date()
        for connection in mounted {
            let id = connection.id
            let manager = NSFileProviderManager(for: domain(for: connection))
            if uploads[id] == nil {
                uploads[id] = manager?.globalProgress(for: .uploading)
            }
            if downloads[id] == nil {
                downloads[id] = manager?.globalProgress(for: .downloading)
            }
            let up = remaining(uploads[id])
            let hasChanged = reportedUploads[id] != up
            reportedUploads[id] = up

            let bytesIn = downloads[id]?.completedUnitCount ?? 0
            if lastDownloaded[id]?.bytes != bytesIn {
                lastDownloaded[id] = (bytesIn, now)
            }
            let isDownloading = now.timeIntervalSince(lastDownloaded[id]?.at ?? .distantPast) < Self.downloadSilence
            let down = isDownloading ? remaining(downloads[id]) : 0
            // Only a real change, so nothing redraws every two seconds for no reason.
            if downloading[id] != down { downloading[id] = down }
            let bytes = uploads[id].map { max(0, $0.totalUnitCount - $0.completedUnitCount) } ?? 0
            if waitingBytes[id] != bytes { waitingBytes[id] = bytes }
            let bytesOut = uploads[id]?.completedUnitCount ?? 0
            if lastUploaded[id]?.bytes != bytesOut {
                lastUploaded[id] = (bytesOut, now)
            }

            let isBusy = up > 0 || !(pending[id] ?? []).isEmpty
            if hasChanged || (isBusy && transferTicks.isMultiple(of: 5)) {
                Task { await refreshPending(of: connection) }
            }
        }
        let free = Self.freeSpace()
        let isLow = free.map { free in
            mounted.contains { connection in
                connection.settings.diskReserve.map { free < $0 } ?? false
            }
        } ?? false
        if isLowOnSpace != isLow { isLowOnSpace = isLow }
    }

    /// What the disk has free for files a person keeps, the figure macOS itself goes by.
    private static func freeSpace() -> Int64? {
        try? URL.homeDirectory
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
    }

    /// Reads which files macOS really has waiting, and what's known about each. A file that's
    /// failing or stopped isn't progress, so only the rest can count as syncing.
    func refreshPending(of connection: Connection) async {
        let id = connection.id
        guard !readingPending.contains(id), connection.isMounted,
              let manager = NSFileProviderManager(for: domain(for: connection)),
              let state = try? await localState(connection)
        else { return }
        readingPending.insert(id)
        defer { readingPending.remove(id) }
        // First, so a file that's been renamed is gone from what's said below.
        await forgetFilesThatWentAway(of: connection, state: state)

        guard let listed = try? await ItemListing.pending(in: manager, limit: Self.pendingLimit) else {
            // macOS wouldn't say, so its progress figure is the best there is. It still has to be
            // backed by proof of movement, or it could turn the sign forever.
            let reported = reportedUploads[id] ?? 0
            if waiting[id] != reported { waiting[id] = reported }
            noteMovement(of: id, waitingFiles: reported > 0 ? ["\(reported)"] : [], state: state)
            Self.log.notice("CM_PENDING: unreadable reported=\(reported, privacy: .public)")
            return
        }
        let failed = (try? state.failures()) ?? []
        let failedIDs = Set(failed.map(\.id))
        let allAttempts = (try? state.attempts()) ?? []
        let attempts = Dictionary(allAttempts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var files = listed.map { item -> PendingFile in
            let isOnServer = (try? state.item(id: item.id)) != nil
            // macOS can call a package by either of its names, and a failure is under only one.
            let unsent = [item.name, FlattenedPackage.twin(of: item.name)].map {
                SyncFailure.unsentID(name: $0, parentID: item.parentID)
            }
            let onRecord = unsent.first { attempts[$0] != nil || failedIDs.contains($0) }
            let key = isOnServer ? item.id : onRecord ?? unsent[0]
            let fileState: PendingFile.State
            if let attempt = attempts[key] {
                fileState = attempt.isHeld ? .held : .failing(attempt)
            } else if failedIDs.contains(key) {
                fileState = .held
            } else if let problem = item.problem {
                fileState = .refused(problem)
            } else {
                fileState = .waiting
            }
            return PendingFile(
                id: key, name: item.name, folder: try? state.path(of: item.parentID), size: item.size,
                state: fileState)
        }
        // macOS's list can be empty while its files are failing, so what's on record counts too.
        let listedIDs = Set(files.map(\.id))
        for attempt in allAttempts where !listedIDs.contains(attempt.id) {
            let location = state.path(of: attempt)
            files.append(PendingFile(
                id: attempt.id, name: attempt.name, folder: location?.parent, size: nil,
                state: attempt.isHeld ? .held : .failing(attempt)))
        }
        let active = files.filter { $0.state == .waiting }
        let failing = files.count { file in
            switch file.state {
            case .failing, .refused: true
            case .waiting, .held: false
            }
        }
        // macOS's progress is the only sign of files it hasn't named, once those with a reason on
        // record are taken out. Those have no names to show, but they're not nothing.
        let unnamed = max(0, (reportedUploads[id] ?? 0) - allAttempts.count)
        let waitingCount = max(active.count, unnamed)
        if pending[id] != files { pending[id] = files }
        if waiting[id] != waitingCount { waiting[id] = waitingCount }
        if retrying[id] != failing { retrying[id] = failing }
        if failures[id] != failed { failures[id] = failed }
        var movement = Set(active.map(\.id))
        if unnamed > active.count {
            movement.insert("unnamed \(unnamed)")
        }
        noteMovement(of: id, waitingFiles: movement, state: state)

        let line = "listed=\(listed.count) reported=\(reportedUploads[id] ?? 0) waiting=\(waitingCount) "
            + "failing=\(failing) failed=\(failed.count) stalled=\(stalled.contains(id))"
        if lastLogged[id] != line {
            lastLogged[id] = line
            Self.log.notice("CM_PENDING: \(line, privacy: .public)")
        }
    }

    /// Decides whether the waiting files are going anywhere. Progress needs proof: a transfer
    /// reporting, a file finishing, the list changing, or macOS seeing upload bytes move.
    private func noteMovement(of id: UUID, waitingFiles: Set<String>, state: SyncStore) {
        let now = Date()
        let finished = (try? state.totals())?.finished ?? 0
        let isRunning = !((try? state.liveTransfers(now: now)) ?? []).isEmpty
        if isRunning || finished != lastFinished[id] || waitingFiles != lastWaiting[id] || lastMoved[id] == nil {
            lastMoved[id] = now
        }
        if let sent = lastUploaded[id]?.at, sent > (lastMoved[id] ?? .distantPast) {
            lastMoved[id] = sent
        }
        lastFinished[id] = finished
        lastWaiting[id] = waitingFiles
        let isStalled = !waitingFiles.isEmpty
            && now.timeIntervalSince(lastMoved[id] ?? now) >= Self.stallLimit
        if isStalled {
            stalled.insert(id)
        } else {
            stalled.remove(id)
        }
    }

    /// Everything the Information page shows, read fresh.
    func report(of connection: Connection) async -> DriveReport {
        guard connection.isMounted, let state = try? await localState(connection) else {
            return DriveReport()
        }
        let failed = (try? state.failures()) ?? []
        var folders: [String: RemotePath] = [:]
        for failure in failed {
            folders[failure.id] = state.path(of: failure)?.parent
        }
        return DriveReport(
            transfers: (try? state.liveTransfers()) ?? [],
            failures: failed,
            failedFolders: folders,
            pending: pending[connection.id] ?? [],
            recent: (try? state.recentActivity()) ?? [],
            totals: (try? state.totals()) ?? SyncTotals(),
            lastChecked: lastChecked[connection.id],
            isBeingChecked: (try? state.isRecovering()) ?? false)
    }

    /// Opens one Finder window with all the mounts selected, then checks every drive, so what
    /// it shows is current. Finder comes first, because a server that's gone can take a while.
    func showMountsInFinder() async {
        isShowingMounts = true
        let started = ContinuousClock.now
        var locations: [URL] = []
        for connection in mounted {
            if let location = await location(of: connection) {
                locations.append(location)
            }
        }
        let claimed = locations.filter { $0.startAccessingSecurityScopedResource() }
        defer {
            claimed.forEach { $0.stopAccessingSecurityScopedResource() }
        }
        if !locations.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(locations)
        }
        await pollOnce(force: true)
        let elapsed = ContinuousClock.now - started
        if elapsed < Self.shortestSyncSign {
            try? await Task.sleep(for: Self.shortestSyncSign - elapsed)
        }
        isShowingMounts = false
    }

    /// Reads what macOS is waiting for a person to allow: each new drive, which does nothing until
    /// it's turned on in System Settings, and launch at login. While either waits, it's read again
    /// every 2 seconds, so its warning goes soon after the person has done it.
    func refreshPermissions() async {
        loginStatus = LoginAgent.status
        if let domains = try? await withinTime(Self.macOSLimit, { try await NSFileProviderManager.domains() }) {
            notEnabled = Set(domains.filter { !$0.userEnabled }.compactMap { UUID(uuidString: $0.identifier.rawValue) })
        }
        watchPermissionsWhileNeeded()
    }

    /// Launch at login was just switched, in this app.
    func noteLoginChanged() {
        loginStatus = LoginAgent.status
        watchPermissionsWhileNeeded()
    }

    private var isWaitingForPermission: Bool {
        needsEnabling || loginStatus == .needsApproval
    }

    private func watchPermissionsWhileNeeded() {
        guard isWaitingForPermission, permissionWatch == nil else { return }
        permissionWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                self.loginStatus = LoginAgent.status
                if let domains = try? await withinTime(Self.macOSLimit, { try await NSFileProviderManager.domains() }) {
                    self.notEnabled = Set(
                        domains.filter { !$0.userEnabled }.compactMap { UUID(uuidString: $0.identifier.rawValue) })
                }
                if !self.isWaitingForPermission {
                    self.permissionWatch = nil
                    return
                }
            }
        }
    }

    /// macOS says when a drive is turned on or off. Coming back from System Settings to any app
    /// reads both permissions again too, in case macOS said nothing.
    private func watchPermissions() {
        NotificationCenter.default.addObserver(
            forName: .fileProviderDomainDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                Task { await self?.refreshPermissions() }
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isWaitingForPermission else { return }
                Task { await self.refreshPermissions() }
            }
        }
    }

    func openExtensionSettings() {
        let address = "x-apple.systempreferences:com.apple.ExtensionsPreferences"
            + "?extensionPointIdentifier=com.apple.fileprovider-nonui"
        if let url = URL(string: address) {
            NSWorkspace.shared.open(url)
        }
    }

    /// Clears the list and macOS's back-off, so it sends failed files again.
    func retryFailed() async {
        for connection in mounted {
            await release(connection)
        }
        await pollOnce(force: true)
    }

    /// The same for one drive, from its Information page.
    func retry(_ connection: Connection) async {
        await release(connection)
        await pollOnce(force: true)
    }

    private func release(_ connection: Connection) async {
        guard let state = try? await localState(connection) else { return }
        try? state.clearAllFailures()
        failures[connection.id] = []
        lastMoved[connection.id] = nil
        stalled.remove(connection.id)
        await clearThrottling(of: connection)
        // Only from here: this asks macOS to send everything it left out, so it's for a person.
        if let manager = NSFileProviderManager(for: domain(for: connection)) {
            _ = try? await withinTime(Self.macOSLimit) {
                try? await manager.signalErrorResolved(NSFileProviderError(.excludedFromSync))
            }
        }
        try? await signal(connection)
    }

    // MARK: Pinned folders

    /// The folders at the top of a drive, which is where pinning is offered.
    func topFolders(of connection: Connection) async -> [SyncItem] {
        guard let drive = try? await opened(connection),
              let children = try? drive.state.children(of: SyncItem.rootID)
        else { return [] }
        return children.filter { $0.kind == .directory }
    }

    func setPinned(_ folder: SyncItem, in connection: Connection, isPinned: Bool) async {
        guard let drive = try? await opened(connection) else { return }
        try? drive.state.setPinned(id: folder.id, isPinned: isPinned)
        try? await signalPendingChanges(of: connection, state: drive.state)
    }

    // MARK: Trash

    func trashEntries(of connection: Connection) async throws -> [RemoteEngine.TrashEntry] {
        try await opened(connection).engine.trashEntries()
    }

    func restore(_ entry: RemoteEngine.TrashEntry, in connection: Connection) async throws {
        let drive = try await opened(connection)
        let restored = try await drive.engine.restoreFromTrash(entry.id)
        // This Mac remembers its own delete, which would hide what came back from every listing.
        if let restored, let folder = try? drive.state.forgetDeletion(at: restored) {
            _ = try? await drive.syncer.refresh(folderID: folder)
            try? await signal(connection)
        }
        await pollOnce(force: true)
    }

    func trashRetentionSeconds(of connection: Connection) async -> Int? {
        try? await opened(connection).engine.trashRetentionSeconds()
    }

    func setTrashRetention(seconds: Int, of connection: Connection) async throws {
        try await opened(connection).engine.setTrashRetention(seconds: seconds)
        // The next poll goes by the new time, instead of waiting out the old one.
        trashRetention[connection.id] = seconds
        lastTrashPass[connection.id] = nil
    }

    // MARK: Recovery

    /// Tries everything that can't lose data: reconnect, recheck, and have macOS look at the
    /// whole drive again. Unsent files stay exactly where they are.
    func repair(_ connection: Connection) async throws {
        store?.diagnostics.record("\(connection.displayName): repair started")
        open[connection.id] = nil
        let drive = try await opened(connection)
        try await drive.engine.checkHealth()
        try? drive.state.clearAllFailures()
        await clearThrottling(of: connection)
        try await signal(connection)
        // Before asking, because a small import can finish before the call returns.
        try drive.state.noteImportStarted()
        try await reimport(connection)
        await pollOnce(force: true)
        store?.diagnostics.record("\(connection.displayName): repair finished")
    }

    /// The last resort, and only ever at someone's request: removes the drive, keeping unsent
    /// files, and adds it again. What macOS keeps is listed in Settings.
    func reset(_ connection: Connection) async throws {
        guard let store else { throw DriveError.noSharedFolder }
        store.diagnostics.record("\(connection.displayName): reset requested")
        let credentials = try store.credentials(for: connection.id)
        // Starting again needs the server, so nothing is removed unless it's there now.
        try await opened(connection).engine.checkHealth()
        try await replace(connection, with: connection, credentials: credentials)
    }

    /// Swaps a drive for a new one, for a reset or a new location. The new record and its secrets
    /// are saved before the old ones go, because a password held only in memory dies with a crash
    /// or a failed step, and an encryption password may exist nowhere else. It's saved as active,
    /// so whatever a crash leaves, repair finishes the old drive and registers this one.
    private func replace(_ old: Connection, with new: Connection, credentials: Credentials) async throws {
        guard let store else { throw DriveError.noSharedFolder }
        var fresh = new
        fresh.id = UUID()
        fresh.lifecycle = .active
        do {
            try store.save(credentials, for: fresh.id)
            try store.save(fresh)
        } catch {
            try? store.remove(id: fresh.id)
            throw error
        }
        var removing = old
        removing.lifecycle = .removing
        do {
            try store.save(removing)
            reload()
            try await finishRemoving(removing)
        } catch {
            // macOS kept the old drive, so nothing has changed yet.
            try? store.save(old)
            try? store.remove(id: fresh.id)
            reload()
            throw error
        }
        try await NSFileProviderManager.add(domain(for: fresh))
        reload()
    }

    /// Only whether a key exists goes into a setup code, never the key.
    func signsInWithKey(_ connection: Connection) -> Bool {
        (try? store?.credentials(for: connection.id))?.privateKeyPEM != nil
    }

    func retireVault(of connection: Connection) async throws {
        try await opened(connection).engine.retireVault()
        store?.diagnostics.record("\(connection.displayName): vault retired")
    }

    func recoveryKit(for connection: Connection) async throws -> String {
        guard let store else { throw DriveError.noSharedFolder }
        let details = try await opened(connection).engine.vaultDetails()
        let credentials = try store.credentials(for: connection.id)
        return RecoveryKit(
            driveName: connection.displayName,
            address: ConnectionSummary.address(of: connection),
            password: credentials.vaultPassword ?? "",
            salt: details.salt,
            vaultID: details.vaultID
        ).text
    }

    /// Only what's needed to help: versions, what kinds of drives exist, and recent events.
    func diagnosticsText() -> String {
        let system = ProcessInfo.processInfo.operatingSystemVersionString
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        var lines = ["CloudAccess \(version), macOS \(system)"]
        for connection in connections {
            lines.append(ConnectionSummary.line(for: connection, status: status(of: connection).label))
        }
        let monitors = ConnectionSummary.monitoringApps(
            running: NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        if !monitors.isEmpty {
            lines.append("Apps that can slow previews: \(monitors.joined(separator: ", "))")
        }
        return store?.diagnostics.exportedText(header: lines.joined(separator: "\n")) ?? ""
    }

    /// Tells macOS about anything the change log holds that it hasn't heard yet. This comes
    /// from the log, not from this poll, so a failed signal or a crash is repaired next time.
    private func signalPendingChanges(of connection: Connection, state: SyncStore) async throws {
        guard let sequence = try state.pendingSignal() else { return }
        do {
            try await signal(connection)
        } catch {
            // macOS not answering says nothing about the server, and the log keeps this pending.
            store?.diagnostics.record("\(connection.displayName): macOS wasn't told of changes: \(error)")
            return
        }
        try state.markSignalled(upTo: sequence)
    }

    /// macOS backs off after errors, so it needs telling when they're over.
    private func clearThrottling(of connection: Connection) async {
        guard let manager = NSFileProviderManager(for: domain(for: connection)) else { return }
        _ = try? await withinTime(Self.macOSLimit) {
            try? await manager.signalErrorResolved(NSFileProviderError(.serverUnreachable))
            try? await manager.signalErrorResolved(NSFileProviderError(.notAuthenticated))
            try? await manager.signalErrorResolved(NSFileProviderError(.cannotSynchronize))
        }
    }

    /// Prunes old history and backs up the database, once a day, and clears old trash when it's due.
    private func houseKeep(_ connection: Connection, drive: OpenDrive) async {
        clearTrash(of: connection, drive: drive)
        let now = Date()
        if let last = lastHousekeeping[connection.id],
           now.timeIntervalSince(last) < Self.housekeepingInterval { return }
        lastHousekeeping[connection.id] = now
        try? drive.state.prune(now: now)
        if let backup = try? store?.backupURL(for: connection.id) {
            try? drive.state.backUp(to: backup)
        }
    }

    /// Beside the poll, because a short time asks for this every minute, and thousands of deleted
    /// files would hold up news from the server. This only decides when to look: the server's
    /// policy and clock decide what goes, so a wrong time here can't purge anything early.
    private func clearTrash(of connection: Connection, drive: OpenDrive) {
        guard !connection.isReadOnly, !clearingTrash.contains(connection.id) else { return }
        let now = Date()
        let interval = TrashRetention.passInterval(retention: trashRetention[connection.id])
        if let last = lastTrashPass[connection.id], now.timeIntervalSince(last) < interval { return }
        lastTrashPass[connection.id] = now
        clearingTrash.insert(connection.id)
        Task {
            defer { clearingTrash.remove(connection.id) }
            guard let result = try? await drive.engine.maintain() else { return }
            if let seconds = result.retentionSeconds {
                trashRetention[connection.id] = seconds
            }
            if let skipped = result.purgeSkipped {
                store?.diagnostics.record("\(connection.displayName): trash not purged: \(skipped)")
            }
        }
    }

    /// Checks the cache figures against what macOS really holds, which also keeps the folders
    /// on disk counted as in use.
    private func reconcile(_ connection: Connection, state: SyncStore) async {
        let now = Date()
        if let last = lastReconcile[connection.id],
           now.timeIntervalSince(last) < Self.reconcileInterval { return }
        lastReconcile[connection.id] = now
        guard let manager = NSFileProviderManager(for: domain(for: connection)),
              let found = try? await ItemListing.onDisk(in: manager)
        else { return }
        #if DEBUG
        NSLog("CM_ONDISK: %@ items=%d dated=%d", connection.displayName, found.ids.count, found.lastUsed.count)
        #endif
        try? state.reconcile(onDisk: found.ids, lastUsed: found.lastUsed, now: now)
    }

    /// Keeps storage on the server: removes local copies the drive's settings no longer call
    /// for. macOS refuses to evict a file with unsent changes or one that's open, so a
    /// failure here is normal, and the file is simply tried again on a later poll.
    private func removeLocalCopies(of connection: Connection, state: SyncStore) async {
        guard let manager = NSFileProviderManager(for: domain(for: connection)) else { return }
        var settings = connection.settings
        #if DEBUG
        if let seconds = ProcessInfo.processInfo.environment["CM_TEST_REMOVE_AFTER"].flatMap(TimeInterval.init) {
            settings.removeLocalCopyAfter = seconds
        }
        #endif
        let planned = Date()
        let chosen = (try? state.copiesToRemove(
            idleFor: settings.removeLocalCopyAfter,
            sizeLimit: limit(for: settings, state: state),
            now: planned)) ?? []
        for id in chosen {
            do {
                try await withinTime(Self.macOSLimit) {
                    try await manager.evictItem(identifier: NSFileProviderItemIdentifier(id))
                }
                try? state.clearLocal(id: id, usedBefore: planned)
                #if DEBUG
                NSLog("CM_EVICT: %@ %@", connection.displayName, id)
                #endif
            } catch is TimedOut {
                // macOS isn't answering, so the rest can wait for a later poll.
                return
            } catch {
                #if DEBUG
                NSLog("CM_EVICT: refused %@: %@", id, String(describing: error))
                #endif
            }
        }
    }

    /// The size limit, lowered if the disk has fallen below its reserve.
    private func limit(for settings: DriveSettings, state: SyncStore) -> Int64? {
        guard let reserve = settings.diskReserve,
              let free = Self.freeSpace(),
              free < reserve,
              let cached = try? state.localCopiesSize()
        else { return settings.sizeLimit }
        let room = max(0, cached - (reserve - free))
        return min(settings.sizeLimit ?? .max, room)
    }

    /// Saves edited connection details. Nothing changes unless the new details really connect.
    /// A new name or sign-in changes the drive where it is. A new location needs a new drive,
    /// because macOS's copy of the items describes the old one, and that goes through the same
    /// protected removal as any other, so unsent files are kept.
    func saveEdit(of connection: Connection, as edited: Connection, signIn: SignInEdit) async throws {
        guard let store else { throw DriveError.noSharedFolder }
        guard !isUninstalling else { throw DriveError.uninstalling }
        #if DEBUG
        guard edited.isTestDrive else { throw DriveError.notATestFolder }
        #endif
        let others = connections.filter { $0.id != connection.id }
        guard !others.contains(where: { $0.displayName == edited.displayName }) else {
            throw DriveError.duplicateName
        }
        guard !others.contains(where: { !$0.requiresNewDrive(comparedTo: edited) }) else {
            throw DriveError.duplicateDrive
        }
        guard DriveEdit.modeRefusal(for: edited) == nil else { throw DriveError.unsafeNeedsSFTP }
        let savedSignIn = try store.credentials(for: connection.id)
        let credentials = signIn.applied(to: savedSignIn)
        let isMoved = edited.requiresNewDrive(comparedTo: connection)
        var saved = edited
        if isMoved || !signIn.isEmpty {
            let engine = try await RemoteEngine(
                connection: edited, credentials: credentials,
                createVault: isMoved && edited.isEncrypted && !edited.isReadOnly)
            _ = try await engine.list(.root)
            if isMoved {
                saved.vaultID = engine.vault?.id
                saved.vaultRevision = engine.vault?.revision
                saved.serverIsReadOnly = false
                if !edited.settings.isReadOnly {
                    saved.serverIsReadOnly = await mustBeReadOnly(engine)
                }
            }
        }

        if isMoved && connection.isMounted {
            store.diagnostics.record("\(connection.displayName): moved to a new location")
            try await replace(connection, with: saved, credentials: credentials)
            return
        }

        try store.save(saved)
        if isMoved || !signIn.isEmpty {
            try store.save(credentials, for: connection.id)
        }
        if connection.isMounted {
            if !signIn.isEmpty {
                open[connection.id] = nil
                try await localState(connection).raiseSignInRevision()
                await clearThrottling(of: connection)
            }
            if saved.displayName != connection.displayName {
                try await NSFileProviderManager.add(domain(for: saved))
            }
        }
        store.diagnostics.record("\(saved.displayName): connection details changed")
        reload()
        if !signIn.isEmpty {
            await pollOnce()
        }
    }

    /// Saves a change of settings. Local files aren't touched until the next poll applies it.
    func update(_ connection: Connection) {
        let previous = connections.first { $0.id == connection.id }
        try? store?.save(connection)
        reload()
        guard let previous else { return }
        // The engine applies the mode itself, so both processes have to reconnect. Items carry
        // their write capabilities, so after a read-only change macOS has to see them again.
        let capabilitiesChanged = previous.isReadOnly != connection.isReadOnly
        if capabilitiesChanged || previous.settings.mode != connection.settings.mode {
            open[connection.id] = nil
            Task {
                try? await localState(connection).raiseSignInRevision()
                if capabilitiesChanged {
                    try? await NSFileProviderManager(for: domain(for: connection))?
                        .reimportItems(below: .rootContainer)
                }
            }
        }
    }

    /// This Mac, as the extension names it to the server.
    private func thisDevice(_ store: DriveStore) -> DeviceInfo? {
        guard let id = try? store.deviceID() else { return nil }
        return DeviceInfo(id: id, name: Host.current().localizedName ?? "Mac")
    }

    /// What the hidden `.cloudmount` folder on this drive's server holds.
    func controlFolder(of connection: Connection) async throws -> RemoteEngine.ControlFolder {
        try await opened(connection).engine.controlFolder()
    }

    /// Removes the hidden `.cloudmount` folder, keeping an encrypted drive's vault, once a person
    /// has agreed. A Read-only drive refuses every write, so this opens its own connection in
    /// Unsafe mode, used for nothing else.
    func cleanControlFolder(of connection: Connection) async throws -> RemoteEngine.ControlFolder {
        guard let store else { throw DriveError.noSharedFolder }
        var cleaning = connection
        cleaning.settings.mode = .unsafe
        let engine = try await RemoteEngine(
            connection: cleaning, credentials: store.credentials(for: connection.id),
            device: thisDevice(store))
        let result = try await engine.cleanControlFolder()
        store.diagnostics.record("\(connection.displayName): removed the server's .cloudmount folder")
        return result
    }

    /// Accepts a server's new key, after a person has compared it.
    func trustHostKey(_ key: String, of connection: Connection) async throws {
        guard let store else { throw DriveError.noSharedFolder }
        var changed = connection
        changed.hostKey = key
        try store.save(changed)
        changedHostKeys.remove(connection.id)
        open[connection.id] = nil
        try await localState(connection).raiseSignInRevision()
        await clearThrottling(of: connection)
        reload()
        await pollOnce()
    }

    /// A drive's database, which needs no connection.
    private func localState(_ connection: Connection) async throws -> SyncStore {
        // Every way to a drive's database comes through here.
        guard !isStopped else { throw CancellationError() }
        if let existing = states[connection.id], existing.isCurrent {
            return existing
        }
        guard let store else { throw DriveError.noSharedFolder }
        let opening = try SyncStore.opening(
            url: store.databaseURL(for: connection.id), backup: store.backupURL(for: connection.id))
        states[connection.id] = opening.store
        if opening.recovery != .none {
            store.diagnostics.record("\(connection.displayName): database recovered: \(opening.recovery)")
        }
        return opening.store
    }

    private func opened(_ connection: Connection) async throws -> OpenDrive {
        // The extension can repair the database too, and then this handle is on the old file.
        if let existing = open[connection.id], existing.state.isCurrent {
            return existing
        }
        guard let store else { throw DriveError.noSharedFolder }
        let state = try await localState(connection)
        // The same device as the extension's, so maintenance knows this Mac's own uploads.
        let engine = try await RemoteEngine(
            connection: connection, credentials: store.credentials(for: connection.id),
            device: thisDevice(store))
        let drive = OpenDrive(engine: engine, syncer: Syncer(store: state, backend: engine), state: state)
        open[connection.id] = drive
        return drive
    }

    private func signal(_ connection: Connection) async throws {
        guard let manager = NSFileProviderManager(for: domain(for: connection)) else { return }
        try await withinTime(Self.macOSLimit) {
            try await manager.signalEnumerator(for: .workingSet)
        }
    }

    private func reimport(_ connection: Connection) async throws {
        guard let manager = NSFileProviderManager(for: domain(for: connection)) else { return }
        try await withinTime(Self.macOSLimit) {
            try await manager.reimportItems(below: .rootContainer)
        }
    }

    // MARK: Test hook

    #if DEBUG
    private func addSFTPTestDrive(_ environment: [String: String], host: String) async throws {
        let port = environment["CM_TEST_SFTP_PORT"].flatMap(Int.init) ?? 22
        let hostKey = try await RemoteEngine.hostKey(host: host, port: port)
        let isEncrypted = environment["CM_TEST_VAULT_PASSWORD"] != nil
        let connection = Connection(
            displayName: "CloudAccess SFTP Test",
            endpoint: .sftp(host: host, port: port),
            username: environment["CM_TEST_SFTP_USER"] ?? "",
            rootPath: environment["CM_TEST_SFTP_PATH"] ?? "",
            isEncrypted: isEncrypted,
            hostKey: hostKey.key)
        let credentials = Credentials(
            password: environment["CM_TEST_SFTP_PASSWORD"],
            privateKeyPEM: environment["CM_TEST_SFTP_KEY_PEM"],
            vaultPassword: environment["CM_TEST_VAULT_PASSWORD"])
        try await add(connection, credentials: credentials)
    }

    /// Lets a test act on the running app with `notifyutil -p`, without touching its menu.
    private func listenForTestCommands() {
        func listen(_ command: String, _ action: @escaping @MainActor () -> Void) {
            var token: Int32 = 0
            notify_register_dispatch("com.infinitecontext.CloudAccess.test.\(command)", &token, .main) { _ in
                MainActor.assumeIsolated(action)
            }
        }
        listen("quit") { LoginAgent.quit() }
        listen("agent-on") { LoginAgent.set(true) }
        listen("agent-off") { LoginAgent.set(false) }
        listen("refresh") { [weak self] in Task { await self?.pollOnce(force: true) } }
        listen("memory-normal") { [weak self] in self?.memory?.simulate(.normal) }
        listen("memory-warning") { [weak self] in self?.memory?.simulate(.warning) }
        listen("memory-critical") { [weak self] in self?.memory?.simulate(.critical) }
        listen("finder-check") { [weak self] in Task { await self?.reportFinderAccess() } }
        listen("menu-check") { StatusPanel.current?.reportLayout() }
        listen("edit-check") { [weak self] in Task { await self?.reportEditGuard() } }
        listen("edit-rename") { [weak self] in self?.editTestDrive(rename: true) }
        listen("edit-signin") { [weak self] in self?.editTestDrive(signIn: SignInEdit(password: "new sign-in")) }
        listen("edit-move") { [weak self] in self?.editTestDrive(move: true) }
        listen("pin-test") { [weak self] in self?.pinTestFolder() }
        listen("toggle-webdav") { [weak self] in self?.toggleTestDrive(named: "CloudAccess Test") }
        listen("toggle-sftp") { [weak self] in self?.toggleTestDrive(named: "CloudAccess SFTP Test") }
        for mode in DriveMode.allCases {
            listen("mode-\(mode.rawValue)") { [weak self] in self?.setTestDriveMode(mode) }
        }
        listen("mode-clean") { [weak self] in self?.cleanTestDriveControlFolder() }
    }

    /// The SFTP test drive, the only one whose mode a test may change.
    private var sftpTestDrive: Connection? {
        connections.first { $0.isTestDrive && $0.displayName == "CloudAccess SFTP Test" }
    }

    /// Goes through the same call as the Mode menu in Advanced.
    private func setTestDriveMode(_ mode: DriveMode) {
        guard var connection = sftpTestDrive else { return }
        connection.settings.mode = mode
        update(connection)
        testReports.notice("CM_MODE: \(mode.rawValue, privacy: .public)")
    }

    private func cleanTestDriveControlFolder() {
        guard let connection = sftpTestDrive else { return }
        Task {
            do {
                let result = try await cleanControlFolder(of: connection)
                testReports.notice("CM_MODE: cleaned vault=\(result.hasVault)")
            } catch {
                testReports.notice("CM_MODE: clean failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Pins or unpins a folder called pinned-test, through the same call as the switch in Advanced.
    private func pinTestFolder() {
        guard let connection = connections.first(where: {
            if case .webDAV = $0.endpoint { return $0.isTestDrive }
            return false
        }) else { return }
        Task {
            guard let drive = try? await opened(connection),
                  let folder = try? drive.state.child(of: SyncItem.rootID, named: "pinned-test")
            else { return }
            await setPinned(folder, in: connection, isPinned: !folder.isPinned)
        }
    }

    /// Goes through the same form and save as a person's edit.
    private func editTestDrive(rename: Bool = false, move: Bool = false, signIn: SignInEdit = SignInEdit()) {
        let suffix = " Renamed"
        let moved = "/moved/" + Connection.testFolderName
        guard let connection = connections.first(where: {
            if case .webDAV = $0.endpoint { return $0.isTestDrive }
            return false
        }) else { return }
        var form = ConnectionForm(connection)
        if rename {
            form.name = form.name.hasSuffix(suffix) ? String(form.name.dropLast(suffix.count)) : form.name + suffix
        }
        if move {
            form.path = form.path == moved ? "/" + Connection.testFolderName : moved
        }
        guard let edited = form.applied(to: connection) else { return }
        Task {
            do {
                try await saveEdit(of: connection, as: edited, signIn: signIn)
                testReports.notice("CM_EDIT: saved")
            } catch {
                testReports.notice("CM_EDIT: failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func toggleTestDrive(named name: String) {
        guard let connection = connections.first(where: { $0.isTestDrive && $0.displayName == name }) else { return }
        Task { await toggleMount(connection) }
    }

    /// Whether an edit pointing away from a test folder is refused. A refusal comes before any
    /// connection, so this changes nothing and reaches no server.
    private func reportEditGuard() async {
        guard let connection = connections.first(where: \.isTestDrive) else { return }
        var edited = connection
        edited.endpoint = .sftp(host: "invalid.example", port: 22)
        edited.rootPath = "/not-a-test-folder"
        do {
            try await saveEdit(of: connection, as: edited, signIn: SignInEdit())
            testReports.notice("CM_EDIT: NOT refused")
        } catch DriveError.notATestFolder {
            testReports.notice("CM_EDIT: refused before connecting")
        } catch {
            testReports.notice("CM_EDIT: other error: \(String(describing: error), privacy: .public)")
        }
    }

    /// Whether the app can reach what it asks Finder to open, without opening a window.
    private func reportFinderAccess() async {
        for connection in mounted where connection.isTestDrive {
            guard let url = await location(of: connection) else {
                testReports.notice("CM_FINDER: \(connection.displayName, privacy: .public): no location")
                continue
            }
            let isClaimed = url.startAccessingSecurityScopedResource()
            let isReadable = await Task.detached {
                (try? FileManager.default.contentsOfDirectory(atPath: url.path)) != nil
            }.value
            testReports.notice(
                "CM_FINDER: \(connection.displayName, privacy: .public): claimed=\(isClaimed) readable=\(isReadable)")
            if isClaimed {
                url.stopAccessingSecurityScopedResource()
            }
        }
    }

    /// Damages a test drive's database before anything opens it, for the recovery test. It's
    /// done here because macOS closes the app's container to other programs.
    private func damageTestDatabase(_ how: String, driveName: String) {
        guard let store else { return }
        for connection in connections where connection.isTestDrive && connection.displayName == driveName {
            guard let database = try? store.databaseURL(for: connection.id) else { continue }
            for suffix in ["-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: database.path + suffix)
            }
            if how == "damage" {
                let noise = (0..<16_384).map { _ in UInt8.random(in: 0...255) }
                try? Data(noise).write(to: database)
            } else {
                try? FileManager.default.removeItem(at: database)
            }
            if how == "nobackup", let backup = try? store.backupURL(for: connection.id) {
                try? FileManager.default.removeItem(at: backup)
            }
            NSLog("CM_TEST: database %@", how)
        }
    }

    /// Lets automated tests add or remove a drive at launch, without the settings UI. Removal
    /// only touches test drives, and goes through the same protected path as a person's.
    private func runTestHook() {
        listenForTestCommands()
        let environment = ProcessInfo.processInfo.environment
        if let how = environment["CM_TEST_DAMAGE_DATABASE"], let name = environment["CM_TEST_DRIVE_NAME"] {
            damageTestDatabase(how, driveName: name)
        }
        if environment["CM_TEST_CLEANUP"] != nil {
            Task {
                for connection in connections where connection.isTestDrive {
                    try? await remove(connection)
                }
                NSLog("CM_TEST: cleaned up")
                NSApp.terminate(nil)
            }
        } else if let host = environment["CM_TEST_SFTP_HOST"] {
            Task {
                do {
                    try await addSFTPTestDrive(environment, host: host)
                    NSLog("CM_TEST: added drive")
                } catch {
                    NSLog("CM_TEST: failed: %@", String(describing: error))
                }
            }
        } else if let address = environment["CM_TEST_WEBDAV_URL"], let url = URL(string: address) {
            let isEncrypted = environment["CM_TEST_VAULT_PASSWORD"] != nil
            let connection = Connection(
                displayName: environment["CM_TEST_DRIVE_NAME"] ?? "CloudAccess Test",
                endpoint: .webDAV(url: url),
                username: environment["CM_TEST_WEBDAV_USER"] ?? "",
                isEncrypted: isEncrypted)
            let credentials = Credentials(
                password: environment["CM_TEST_WEBDAV_PASSWORD"],
                vaultPassword: environment["CM_TEST_VAULT_PASSWORD"])
            Task {
                do {
                    try await add(connection, credentials: credentials)
                    NSLog("CM_TEST: added drive")
                } catch {
                    NSLog("CM_TEST: failed: %@", String(describing: error))
                }
            }
        }
    }
    #endif

    // MARK: Adding and removing

    /// Verifies the connection and the vault, saves it, and adds it to the Finder sidebar.
    /// The record is saved as `adding` first, so a crash at any step can be finished or undone.
    /// - Parameter mayCreateVault: False for a drive from a drives file, which must only ever
    ///   join the vault it came from, never start a new one with a new key in an empty folder.
    @discardableResult
    func add(_ connection: Connection, credentials: Credentials, mayCreateVault: Bool = true) async throws -> Connection {
        guard let store else { throw DriveError.noSharedFolder }
        guard !isUninstalling else { throw DriveError.uninstalling }
        guard DriveEdit.modeRefusal(for: connection) == nil else { throw DriveError.unsafeNeedsSFTP }
        guard !connections.contains(where: { $0.displayName == connection.displayName }) else {
            throw DriveError.duplicateName
        }
        // Two drives on one folder would be two databases and two sets of claims on the same files.
        guard !connections.contains(where: { !$0.requiresNewDrive(comparedTo: connection) }) else {
            throw DriveError.duplicateDrive
        }
        #if DEBUG
        guard connection.isTestDrive else { throw DriveError.notATestFolder }
        #endif

        let engine = try await RemoteEngine(
            connection: connection, credentials: credentials,
            createVault: mayCreateVault && connection.isEncrypted && !connection.isReadOnly)
        _ = try await engine.list(.root)

        var saved = connection
        saved.vaultID = engine.vault?.id
        saved.vaultRevision = engine.vault?.revision
        if !saved.settings.isReadOnly {
            saved.serverIsReadOnly = await mustBeReadOnly(engine)
        }
        saved.lifecycle = .adding

        try store.save(credentials, for: saved.id)
        do {
            try store.save(saved)
            try await NSFileProviderManager.add(domain(for: saved))
        } catch {
            try? store.remove(id: saved.id)
            throw error
        }
        // The domain exists now, so the record has to stay. If this write fails, repair finishes
        // the job at the next launch.
        saved.lifecycle = .active
        try? store.save(saved)
        reload()
        return saved
    }

    // MARK: Drives file

    /// The drives a person can put in a drives file: ones fully added, not half added or removed.
    var exportable: [Connection] {
        connections.filter { $0.lifecycle == .active }
    }

    /// Seals the chosen drives and their passwords into a drives file's bytes.
    func drivesFile(of ids: Set<UUID>, password: String) throws -> Data {
        guard let store else { throw DriveError.noSharedFolder }
        let entries = try exportable.filter { ids.contains($0.id) }.map { connection in
            DrivesFile.Entry(connection, credentials: try store.credentials(for: connection.id))
        }
        let data = try DrivesFile.seal(entries, password: password)
        store.diagnostics.record("Exported \(entries.count) drives to a drives file")
        return data
    }

    /// Carries out the step a person chose for one drive in a drives file. It either finishes or
    /// changes nothing, and it never touches any other drive.
    func importStep(
        _ step: DrivesFileImport.Step, for row: DrivesFileImport.Row, allowsInsecure: Bool
    ) async throws {
        switch step {
        case .skip:
            return
        case .add, .addAs:
            guard let connection = DrivesFileImport.newDrive(for: row, step: step, allowsInsecure: allowsInsecure)
            else { throw DriveError.insecureNotAllowed }
            // Add is all or nothing by itself: what it saved is removed if adding the location fails.
            try await add(connection, credentials: row.entry.credentials, mayCreateVault: false)
        case .updatePasswords, .updatePasswordsAndSettings:
            guard case .alreadyHere(let id) = row.situation,
                  let existing = connections.first(where: { $0.id == id }),
                  let updated = DrivesFileImport.updatedDrive(existing, for: row, step: step)
            else { return }
            try await updateFromFile(existing, as: updated, credentials: row.entry.credentials)
        }
    }

    /// Gives a drive already here the passwords, and maybe the settings, from a drives file. They're
    /// tried on the server first, so nothing is saved unless they work.
    private func updateFromFile(_ existing: Connection, as updated: Connection, credentials: Credentials) async throws {
        guard let store else { throw DriveError.noSharedFolder }
        guard DriveEdit.modeRefusal(for: updated) == nil else { throw DriveError.unsafeNeedsSFTP }
        let engine = try await RemoteEngine(connection: updated, credentials: credentials)
        _ = try await engine.list(.root)
        let previous = try store.credentials(for: existing.id)
        try await DrivesFileImport.allOrNothing([
            DrivesFileImport.Action(
                run: { try store.save(credentials, for: existing.id) },
                undo: { try? store.save(previous, for: existing.id) }),
            // The extension keeps its connection, so it has to be told to sign in again.
            DrivesFileImport.Action(run: { try await self.localState(existing).raiseSignInRevision() }),
        ])
        open[existing.id] = nil
        if updated.settings != existing.settings {
            update(updated)
        }
        store.diagnostics.record("\(existing.displayName): passwords updated from a drives file")
    }

    /// A server that reports no versions can't be saved to safely, and one that refuses the
    /// probe can't be saved to at all.
    private func mustBeReadOnly(_ engine: RemoteEngine) async -> Bool {
        do {
            return !(try await engine.reportsVersions())
        } catch RemoteError.forbidden {
            return true
        } catch {
            return false
        }
    }

    /// Unsent files are kept: `preserveDirtyUserData` never discards local changes. The
    /// connection and its secrets are only deleted once macOS has removed the drive.
    /// - Returns: Where macOS kept files that hadn't uploaded, if it kept any.
    @discardableResult
    func remove(_ connection: Connection) async throws -> String? {
        guard let store else { throw DriveError.noSharedFolder }
        var removing = connection
        removing.lifecycle = .removing
        try store.save(removing)
        reload()
        return try await finishRemoving(removing)
    }

    /// Whether macOS still has a drive's domain. If its list can't be read, the domain is taken to
    /// be there, so removal still asks macOS, as it always has.
    private func hasDomain(_ connection: Connection) async -> Bool {
        guard let domains = try? await NSFileProviderManager.domains() else { return true }
        return domains.contains { $0.identifier.rawValue == connection.id.uuidString }
    }

    /// Takes a drive out of Finder. Anything unsent is kept where macOS puts it. A domain macOS
    /// has already dropped is left at that, so its record can still go: asking macOS to remove
    /// it again could fail, and leave the record behind for good.
    /// - Returns: Where macOS kept files that hadn't uploaded, if it kept any.
    @discardableResult
    private func removeDomain(of connection: Connection) async throws -> String? {
        guard let store else { return nil }
        open[connection.id] = nil
        states[connection.id] = nil
        offline.remove(connection.id)
        offlineSince[connection.id] = nil
        // These belong to the domain that's going, so a later mount needs new ones.
        uploads[connection.id] = nil
        downloads[connection.id] = nil
        pending[connection.id] = nil
        waiting[connection.id] = nil
        retrying[connection.id] = nil
        reportedUploads[connection.id] = nil
        lastMoved[connection.id] = nil
        lastDownloaded[connection.id] = nil
        lastUploaded[connection.id] = nil
        stalled.remove(connection.id)
        downloading[connection.id] = nil
        problems[connection.id] = nil
        guard await hasDomain(connection) else { return nil }
        let preserved = try await NSFileProviderManager.remove(
            domain(for: connection), mode: .preserveDirtyUserData)
        if let preserved {
            let files = DriveStore.PreservedFiles(driveName: connection.displayName, path: preserved.path)
            do {
                try store.addPreserved(files)
            } catch {
                // macOS gives this only once, so it stays on screen, and polls keep trying to save it.
                unsavedPreserved.append(files)
                store.diagnostics.record(
                    "\(connection.displayName): unsent files are at \(preserved.path), and that couldn't be saved")
            }
        }
        return preserved?.path
    }

    private func saveWaitingPreserved() {
        guard let store, !unsavedPreserved.isEmpty else { return }
        unsavedPreserved.removeAll { (try? store.addPreserved($0)) != nil }
        reload()
    }

    /// Ejects or mounts a drive. Ejecting takes it out of Finder and stops syncing, and keeps its
    /// connection and passwords. Mounting starts it fresh from the server, as a new device would.
    func toggleMount(_ connection: Connection) async {
        guard let store else { return }
        do {
            var changed = connection
            if connection.isMounted {
                guard confirmEject(connection) else { return }
                try await removeDomain(of: connection)
                try? store.deleteDatabase(for: connection.id)
                changed.isMounted = false
                try store.save(changed)
            } else {
                guard !isUninstalling else { return }
                changed.isMounted = true
                try await NSFileProviderManager.add(domain(for: changed))
                try store.save(changed)
            }
            reload()
            if changed.isMounted {
                await pollOnce()
            }
        } catch {
            store.diagnostics.record("\(connection.displayName): couldn't eject or mount: \(error)")
        }
    }

    /// Unsent files can't upload once the drive is gone, so that's worth stopping for.
    private func confirmEject(_ connection: Connection) -> Bool {
        let count = unsentCount(of: connection)
        guard count > 0 else { return true }
        let alert = NSAlert()
        let name = connection.displayName
        alert.messageText = String(localized: "Eject \(name)?")
        alert.informativeText = String(localized: "\(count) files haven't uploaded yet. They'll stay on this Mac, and Settings shows where.")
        alert.addButton(withTitle: String(localized: "Eject"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// An ejected drive normally has no domain, and then this asks macOS nothing. One that has a
    /// domain anyway loses it too, so nothing of the drive is left in Finder.
    @discardableResult
    private func finishRemoving(_ connection: Connection) async throws -> String? {
        guard let store else { return nil }
        let preserved = try await removeDomain(of: connection)
        try store.remove(id: connection.id)
        try? store.deleteDatabase(for: connection.id)
        reload()
        return preserved
    }

    // MARK: Uninstalling

    /// Stops every check, for an uninstall, and waits for one already under way to end. Nothing
    /// in the app can then open a drive's database, which would create it again once deleted.
    /// The app quits after an uninstall, so this is never undone.
    /// - Returns: Whether everything stopped. A check can wait on macOS for up to two minutes.
    func stopForUninstall() async -> Bool {
        isStopped = true
        transfersTask?.cancel()
        pollingTask?.cancel()
        let deadline = Date().addingTimeInterval(180)
        while isPolling || !readingPending.isEmpty, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(200))
        }
        guard !isPolling, readingPending.isEmpty else { return false }
        open = [:]
        states = [:]
        return true
    }

    /// Every drive saved, whatever its state, for an uninstall. The list on screen leaves out
    /// those being added or removed.
    func everySavedDrive() throws -> [Connection] {
        guard let store else { throw DriveError.noSharedFolder }
        return try store.connections()
    }

    /// What's keeping a drive from being ready to remove, for an uninstall's wait.
    func hold(on connection: Connection) -> Uninstall.Hold? {
        guard connection.isMounted, unsentCount(of: connection) > 0 else { return nil }
        if offline.contains(connection.id) { return .offline }
        if !(failures[connection.id] ?? []).isEmpty { return .failing }
        return .uploading
    }

    /// Reads again which files macOS still has to send, for each mounted drive.
    func refreshAllPending() async {
        for connection in mounted {
            await refreshPending(of: connection)
        }
    }

    /// Removes a location macOS has with no drive behind it, keeping anything unsent there.
    /// - Returns: Where macOS kept files that hadn't uploaded, if it kept any.
    func removeOrphanLocation(_ identifier: String) async throws -> String? {
        guard let domain = try await NSFileProviderManager.domains()
            .first(where: { $0.identifier.rawValue == identifier })
        else { return nil }
        let preserved = try await NSFileProviderManager.remove(domain, mode: .preserveDirtyUserData)
        return preserved?.path
    }

    func revealPreserved(_ files: DriveStore.PreservedFiles) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: files.path)])
    }

    func forgetPreserved(_ files: DriveStore.PreservedFiles) {
        unsavedPreserved.removeAll { $0.id == files.id }
        try? store?.removePreserved(id: files.id)
        reload()
    }

    func forgetAllPreserved() {
        unsavedPreserved = []
        for files in preservedFiles {
            try? store?.removePreserved(id: files.id)
        }
        reload()
    }

    /// Where a drive is in Finder. macOS gives this out as a security-scoped address, and the
    /// sandbox refuses it until it's claimed. The refusal looks like a missing permission, but no
    /// setting grants it.
    private func location(of connection: Connection) async -> URL? {
        guard let manager = NSFileProviderManager(for: domain(for: connection)) else { return nil }
        return try? await manager.getUserVisibleURL(for: .rootContainer)
    }

    /// Shows a failed file in Finder, so it can be renamed or moved.
    func reveal(_ failure: SyncFailure) async {
        guard let connection = connections.first(where: { failures[$0.id]?.contains(failure) == true }),
              let state = try? await localState(connection),
              let path = state.path(of: failure)
        else { return }
        await reveal(path, in: connection)
    }

    func reveal(_ file: PendingFile, in connection: Connection) async {
        guard let path = file.folder?.appending(file.name) else { return }
        await reveal(path, in: connection)
    }

    private func reveal(_ path: RemotePath, in connection: Connection) async {
        guard let root = await location(of: connection) else { return }
        let isClaimed = root.startAccessingSecurityScopedResource()
        defer {
            if isClaimed {
                root.stopAccessingSecurityScopedResource()
            }
        }
        let url = path.components.reduce(root) { $0.appending(path: $1) }
        let onDisk = Self.diskNames(of: url).first { FileManager.default.fileExists(atPath: $0.path) }
        NSWorkspace.shared.activateFileViewerSelecting([onDisk ?? url.deletingLastPathComponent()])
    }

    /// Where something can be on the disk. A flattened package is there under its real name.
    private static func diskNames(of url: URL) -> [URL] {
        let shown = FlattenedPackage.shownName(url.lastPathComponent)
        guard shown != url.lastPathComponent else { return [url] }
        return [url, url.deletingLastPathComponent().appending(path: shown)]
    }

    /// A file that never reached the server leaves its failure behind when it's renamed or moved,
    /// because nothing will ever say that name worked.
    private func forgetFilesThatWentAway(of connection: Connection, state: SyncStore) async {
        let unsent = (try? state.unsentFiles()) ?? []
        guard !unsent.isEmpty, let root = await location(of: connection) else { return }
        let isClaimed = root.startAccessingSecurityScopedResource()
        defer {
            if isClaimed {
                root.stopAccessingSecurityScopedResource()
            }
        }
        for failure in unsent {
            guard let path = state.path(of: failure) else { continue }
            let url = path.components.reduce(root) { $0.appending(path: $1) }
            if !Self.diskNames(of: url).contains(where: Self.isThere) {
                try? state.clearFailure(id: failure.id)
            }
        }
    }

    /// Whether a file is on disk under exactly this name. The disk ignores capitals, so one renamed
    /// from `A.txt` to `a.txt` still answers to its old name, and only its real name tells them
    /// apart. Swift's comparison treats the disk's form of an accented letter as the same one.
    private static func isThere(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        guard let name = try? url.resourceValues(forKeys: [.nameKey]).name else { return true }
        return name == url.lastPathComponent
    }

    /// Shows the log in Finder. Writing a line first means there's always a file to select, even
    /// on a Mac where nothing has happened yet.
    func showLogs() {
        guard let log = store?.diagnostics else { return }
        log.record("Logs shown in Finder")
        NSWorkspace.shared.activateFileViewerSelecting([log.file])
    }

    func openInFinder(_ connection: Connection) async {
        guard let url = await location(of: connection) else { return }
        let isClaimed = url.startAccessingSecurityScopedResource()
        defer {
            if isClaimed {
                url.stopAccessingSecurityScopedResource()
            }
        }
        let configuration = NSWorkspace.OpenConfiguration()
        // Finder still shows the drive if this fails, so nobody sees macOS's alert about it.
        configuration.promptsUserIfNeeded = false
        do {
            try await NSWorkspace.shared.open(url, configuration: configuration)
        } catch {
            store?.diagnostics.record("\(connection.displayName): Finder didn't open it: \(error)")
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    private func domain(for connection: Connection) -> NSFileProviderDomain {
        let domain = NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(connection.id.uuidString),
            displayName: connection.displayName)
        // Deleted files go to our own server trash, not a synced File Provider trash.
        domain.supportsSyncingTrash = false
        return domain
    }
}

/// What macOS says about a drive's items, read from its own records.
private enum ItemListing {
    struct OnDisk: Sendable {
        var ids = Set<String>()
        var lastUsed: [String: Date] = [:]
    }

    struct Pending: Sendable {
        let id: String
        let name: String
        let parentID: String
        let size: Int64?
        let problem: String?
    }

    private static func syncID(_ identifier: NSFileProviderItemIdentifier) -> String {
        identifier == .rootContainer ? SyncItem.rootID : identifier.rawValue
    }

    /// Which items are on disk, and when macOS says they were last used.
    static func onDisk(in manager: NSFileProviderManager) async throws -> OnDisk {
        try await EnumeratorReader.read(manager.enumeratorForMaterializedItems(), into: OnDisk()) { found, item in
            let id = syncID(item.itemIdentifier)
            found.ids.insert(id)
            found.lastUsed[id] = item.lastUsedDate ?? nil
            return true
        }
    }

    /// Which items macOS hasn't finished syncing.
    /// - Parameter limit: The most to read. The start of a long list says enough.
    static func pending(in manager: NSFileProviderManager, limit: Int) async throws -> [Pending] {
        try await EnumeratorReader.read(manager.enumeratorForPendingItems(), into: [Pending]()) { found, item in
            if item.itemIdentifier != .rootContainer {
                found.append(Pending(
                    id: syncID(item.itemIdentifier),
                    name: item.filename,
                    parentID: syncID(item.parentItemIdentifier),
                    size: (item.documentSize ?? nil)?.int64Value,
                    problem: (item.uploadingError ?? nil)?.localizedDescription))
            }
            return found.count < limit
        }
    }
}

/// Walks an enumerator from macOS to its end, or until told to stop.
private final class EnumeratorReader<Found: Sendable>: NSObject, NSFileProviderEnumerationObserver, @unchecked Sendable {
    /// macOS answers from its own records, so this is far longer than it needs. Polls run one at
    /// a time, so a read that never came back would stop every drive from being checked.
    private static var limit: Duration { .seconds(60) }

    private let enumerator: NSFileProviderEnumerator
    private let add: (inout Found, any NSFileProviderItemProtocol) -> Bool
    private let lock = NSLock()
    private var found: Found
    private var wantsMore = true
    private var continuation: CheckedContinuation<Found, Error>?

    private init(
        enumerator: NSFileProviderEnumerator, found: Found,
        add: @escaping (inout Found, any NSFileProviderItemProtocol) -> Bool
    ) {
        self.enumerator = enumerator
        self.found = found
        self.add = add
    }

    /// - Parameter add: Takes in one item, and says whether to carry on.
    static func read(
        _ enumerator: NSFileProviderEnumerator, into found: Found,
        add: @escaping (inout Found, any NSFileProviderItemProtocol) -> Bool
    ) async throws -> Found {
        let reader = EnumeratorReader(enumerator: enumerator, found: found, add: add)
        defer { reader.enumerator.invalidate() }
        let timer = Task {
            try await Task.sleep(for: limit)
            reader.finish(.failure(CancellationError()))
        }
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            reader.lock.withLock { reader.continuation = continuation }
            reader.enumerator.enumerateItems(
                for: reader, startingAt: NSFileProviderPage(NSFileProviderPage.initialPageSortedByName as Data))
        }
    }

    /// The first answer wins, because macOS may still call back after the time is up.
    private func finish(_ result: Result<Found, Error>) {
        let waiting = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        waiting?.resume(with: result)
    }

    func didEnumerate(_ updatedItems: [any NSFileProviderItemProtocol]) {
        lock.withLock {
            for item in updatedItems where wantsMore {
                wantsMore = add(&found, item)
            }
        }
    }

    func finishEnumerating(upTo nextPage: NSFileProviderPage?) {
        if let nextPage, lock.withLock({ wantsMore }) {
            enumerator.enumerateItems(for: self, startingAt: nextPage)
        } else {
            finish(.success(lock.withLock { found }))
        }
    }

    func finishEnumeratingWithError(_ error: any Error) {
        finish(.failure(error))
    }
}
