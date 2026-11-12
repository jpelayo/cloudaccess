// Apache 2 license - developer@infinitecontext.com

import CloudCore
import CloudDesign
import Foundation
import RemoteEngine
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Somewhere a person can be: a folder on a drive. Navigation is a list of these, which is what
/// lets the bar at the top show the whole way here, and jump back to any part of it.
struct Place: Hashable {
    let connection: Connection
    let path: RemotePath

    var title: String {
        path.isRoot ? connection.displayName : path.name
    }
}

/// Connections to the drives, and whether they can be reached. There's one connection per drive,
/// so going deeper doesn't sign in again.
@Observable
final class OpenDrives {
    let library = OfflineLibrary(directory: URL.applicationSupportDirectory.appendingPathComponent("Offline"))

    private var engines: [UUID: RemoteEngine] = [:]
    private var watcher: NetworkWatcher?
    private(set) var isNetworkUp = true
    private(set) var unreachable: Set<UUID> = []
    /// Moves on when the network returns, so whatever's on screen tries again.
    private(set) var retry = 0
    /// Why each drive that can't be reached can't, as far as checking proved it.
    let checks = ConnectionChecks(device: .iPhone)
    /// Why this iPhone has no network, read when it went.
    private(set) var deviceNetwork: DeviceNetwork?
    /// Check Again is running.
    private(set) var isCheckingAgain = false
    /// The drives that can't be reached, to try again by themselves.
    private var unreachableDrives: [UUID: Connection] = [:]
    /// The server each reachable drive is on, which is evidence this iPhone's network works.
    private var reachableServers: [UUID: ConnectionCheck.Target] = [:]
    private var rechecking: Task<Void, Never>?

    init() {
        library.clearAbandoned()
        checks.log = { AppLog.record($0) }
        watcher = NetworkWatcher { [weak self] isUp in
            Task { @MainActor [weak self] in self?.networkChanged(isUp: isUp) }
        }
    }

    /// A change with the network still up can be a VPN such as Tailscale coming on, which is what
    /// a drive that can't be reached may be waiting for.
    private func networkChanged(isUp: Bool) {
        let shouldRetry = isUp && (!isNetworkUp || !unreachable.isEmpty)
        if isUp != isNetworkUp {
            AppLog.record(isUp ? "Network available" : "Network lost")
        }
        isNetworkUp = isUp
        if isUp {
            deviceNetwork = nil
            // Interfaces take a moment after a change, so a failure meanwhile isn't judged.
            checks.settle(for: 5)
        } else {
            Task { deviceNetwork = await ConnectionCheck.currentNetwork() }
        }
        if shouldRetry {
            unreachable = []
            unreachableDrives = [:]
            checks.keep(only: [])
            engines = [:]
            retry += 1
        }
        restartRechecking()
    }

    /// What the whole app shows about connections. A drive whose own server fails says so only on
    /// its row and in its folders. Only a problem with this iPhone is shown app-wide.
    var appWideWarning: AppWideWarning {
        if !isNetworkUp {
            let network = deviceNetwork.flatMap { $0.isUp ? nil : $0 } ?? DeviceNetwork(isUp: false, unsatisfied: .notAvailable)
            return .cannotConnect(ConnectionFinding.forDevice(network, device: .iPhone))
        }
        return AppWideWarning.from(unreachable.compactMap { checks.findings[$0] })
    }

    func isOffline(_ connection: Connection) -> Bool {
        !isNetworkUp || unreachable.contains(connection.id)
    }

    /// Why a drive can't connect, in a few words, or nil while that's not known yet.
    func shortReason(for connection: Connection) -> String? {
        if !isNetworkUp {
            return appWideWarning.finding?.shortLabel
        }
        if checks.isSettling || (checks.checking.contains(connection.id) && checks.findings[connection.id] == nil) {
            return String(localized: "checking…")
        }
        return checks.findings[connection.id]?.shortLabel
    }

    /// Why a drive can't connect, in a sentence, or nil while that's not known yet.
    func reason(for connection: Connection) -> String? {
        if !isNetworkUp {
            return appWideWarning.title
        }
        if checks.isSettling {
            return String(localized: "Reconnecting…")
        }
        return checks.findings[connection.id]?.sentence
    }

    func noteReachable(_ connection: Connection) {
        if unreachable.remove(connection.id) != nil {
            AppLog.record("\(connection.displayName): connected again")
        }
        unreachableDrives[connection.id] = nil
        reachableServers[connection.id] = ConnectionCheck.Target(connection)
        checks.keep(only: unreachable)
    }

    /// Logged only when it changes, so a folder opened again while offline adds nothing. A new
    /// failure is checked once, beside whatever's on screen.
    func noteUnreachable(_ connection: Connection, because error: Error) {
        if unreachable.insert(connection.id).inserted {
            AppLog.record("\(connection.displayName): can't connect: \(Diagnostics.kind(of: error))")
        }
        engines[connection.id] = nil
        unreachableDrives[connection.id] = connection
        reachableServers[connection.id] = nil
        checks.noteFailures([(connection, error)]) { [weak self] in self?.connectsToAnotherServer(than: $0) ?? false }
    }

    private func connectsToAnotherServer(than connection: Connection) -> Bool {
        let target = ConnectionCheck.Target(connection)
        return reachableServers.values.contains { $0 != target }
    }

    /// Tries a drive's server again: a new connection and a look at its top folder.
    private func reconnect(_ connection: Connection, store: DriveStore) async -> Bool {
        engines[connection.id] = nil
        do {
            let engine = try await engine(for: connection, store: store)
            _ = try await engine.list(.root)
            noteReachable(connection)
            return true
        } catch {
            if ConnectionFinding.isFor(error) || (error as? RemoteError)?.scope == .connection {
                noteUnreachable(connection, because: error)
            }
            return false
        }
    }

    /// Check Again: connects to each drive again, and checks why any still can't. Whatever is on
    /// screen then loads again.
    func checkAgain(_ chosen: [Connection], store: DriveStore) async {
        guard !isCheckingAgain else { return }
        isCheckingAgain = true
        defer { isCheckingAgain = false }
        if !isNetworkUp {
            deviceNetwork = await ConnectionCheck.currentNetwork()
            return
        }
        var stillDown: [Connection] = []
        for connection in chosen {
            if await !reconnect(connection, store: store) {
                stillDown.append(connection)
            }
        }
        await checks.check(stillDown, byAPerson: true) { [weak self] in self?.connectsToAnotherServer(than: $0) ?? false }
        retry += 1
        restartRechecking()
    }

    /// The drives that can't be reached now.
    var unreachableConnections: [Connection] {
        Array(unreachableDrives.values)
    }

    /// The store the rechecks sign in with, while the app is on screen.
    private var recheckStore: DriveStore?

    /// While the app is in front, a drive that can't be reached is tried again by itself: after
    /// 10, 20 and 40 seconds, then every minute. Check Again does the same at once.
    func startRechecking(store: DriveStore) {
        recheckStore = store
        restartRechecking()
    }

    func stopRechecking() {
        recheckStore = nil
        rechecking?.cancel()
        rechecking = nil
    }

    private func restartRechecking() {
        rechecking?.cancel()
        guard let store = recheckStore else { return }
        rechecking = Task { [weak self] in
            var wait = 10.0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled, let self else { return }
                let down = self.unreachableConnections
                guard self.isNetworkUp, !down.isEmpty else {
                    wait = 10
                    continue
                }
                var anyBack = false
                for connection in down {
                    if await self.reconnect(connection, store: store) {
                        anyBack = true
                    }
                }
                if anyBack {
                    self.retry += 1
                }
                wait = min(wait * 2, 60)
            }
        }
    }

    func engine(for connection: Connection, store: DriveStore) async throws -> RemoteEngine {
        if let engine = engines[connection.id] {
            return engine
        }
        let engine = try await RemoteEngine(
            connection: connection, credentials: store.credentials(for: connection.id))
        engines[connection.id] = engine
        return engine
    }

    /// Drops the connection after a new password, so the next folder opened signs in with it.
    /// What's downloaded stays.
    func reconnect(_ connection: Connection) {
        engines[connection.id] = nil
        unreachable.remove(connection.id)
    }

    func forget(_ connection: Connection) {
        engines[connection.id] = nil
        unreachable.remove(connection.id)
        library.remove(drive: connection.id)
    }
}

/// The red warning shown while a drive can't be reached: app-wide only for a problem with this
/// iPhone, and otherwise only in that drive's own folders.
struct OfflineBar: View {
    /// Why, as far as checking proved it, already in the language shown.
    let reason: String?
    /// When that was found, if a check found it.
    var checked: Date? = nil
    let isChecking: Bool
    let checkAgain: () -> Void
    /// When the fix is a switch in Settings, the bar opens it instead of checking again: coming
    /// back to the app checks by itself.
    var openSettings: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Not connected")
                    .fontWeight(.semibold)
                if let reason {
                    Text(verbatim: reason)
                        .font(.footnote)
                }
                if let checked {
                    CheckedLine(checked: checked)
                        .font(.footnote)
                }
                Text("Files on this iPhone are still available.")
                    .font(.footnote)
            }
            Spacer(minLength: 0)
            Group {
                if let openSettings {
                    Button("Open Settings", action: openSettings)
                } else {
                    CheckAgainButton(isChecking: isChecking, action: checkAgain)
                }
            }
            .buttonStyle(.bordered)
            .tint(.white)
            .font(.footnote)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        // Darker than system red, so white text stays readable on it.
        .background(Color(red: 0.72, green: 0.11, blue: 0.09))
    }
}

/// When a drive's connection was last checked, and that the app keeps checking.
struct CheckedLine: View {
    let checked: Date

    var body: some View {
        let time = checked.formatted(date: .omitted, time: .shortened)
        Text("Checked at \(time). CloudWanderer also checks while it's open.")
    }
}

extension ConnectionFinding.Action {
    /// The app's page in Settings, where Local Network, mobile data and Wi-Fi are allowed.
    var opensSettings: Bool {
        self == .openLocalNetworkSettings || self == .openAppSettings
    }
}

extension View {
    /// Fills the row of a list, so the whole row takes the tap, not only the words.
    func wholeRow() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
    }
}

/// Why the Files app can't use a drive, a word or two each. Side by side when they fit, and one
/// under the other on a narrow iPhone.
struct DrivePills: View {
    struct Pill: Hashable {
        /// Already in the language shown, so the pill shows it as it is.
        let text: String
        let color: Color

        /// Words from this app's catalog.
        init(text: LocalizedStringResource, color: Color) {
            self.text = String(localized: text)
            self.color = color
        }

        /// Words already in the language shown, such as the package's.
        @_disfavoredOverload
        init(text: some StringProtocol, color: Color) {
            self.text = String(text)
            self.color = color
        }
    }

    let pills: [Pill]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { content }
            VStack(alignment: .leading, spacing: 4) { content }
        }
    }

    private var content: some View {
        ForEach(pills, id: \.self) { pill in
            StatusPill(text: pill.text, color: pill.color)
                .fixedSize()
        }
    }
}

/// Read-only: list drives, browse, download and export.
struct DrivesView: View {
    private let store = PhoneDrives.store
    @State private var connections: [Connection] = []
    @State private var trail: [Place] = []
    @State private var drives = OpenDrives()
    @State private var places = FilesPlaces()
    @State private var isAdding = false
    @State private var isShowingAbout = false
    @State private var isShowingCloudAccess = false
    /// Drives files, the Mac app and About, kept off the drives list behind the gear.
    @State private var isShowingSettings = false
    /// A drive whose removal would delete changes kept only on this iPhone, waiting for a yes.
    @State private var removing: Connection?
    @State private var signingIn: Connection?
    @State private var editing: Connection?
    @State private var isExportingDrives = false
    @State private var isChoosingDrivesFile = false
    @State private var importing: DrivesFileToImport?
    @State private var drivesFileProblem: String?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    /// Encrypted drives say so in a pill instead.
    private func kind(of connection: Connection) -> String {
        if case .sftp = connection.endpoint { return "SFTP" }
        return "WebDAV"
    }

    /// The kind of drive, or why it isn't in the Files app when someone would look for it there.
    private func subtitle(for connection: Connection) -> String {
        if let problem = places.problems[connection.id] {
            return String(localized: "Not in Files: \(problem)")
        }
        if places.switchedOff.contains(connection.id) {
            return String(localized: "Off in the Files app. Turn it on there, under Locations.")
        }
        return kind(of: connection)
    }

    /// What keeps the Files app from using a drive, shown in place of the line under its name.
    private func pills(for connection: Connection) -> [DrivePills.Pill] {
        if connection.isEncrypted {
            // Without the App Group nothing is in Files, so there's nothing to be incompatible with.
            let files = PhoneDrives.reachFiles ? [DrivePills.Pill(text: "Incompatible with Files.app", color: .gray)] : []
            return files + [DrivePills.Pill(text: "Encrypted", color: .blue)]
        }
        if places.notes[connection.id]?.problem != nil {
            return [DrivePills.Pill(text: "Files.app needs sign-in", color: .orange)]
        }
        return []
    }

    /// Drives the Files app can't sign in to, which iOS sends here to sign in.
    private var needingSignIn: [Connection] {
        connections.filter { places.notes[$0.id]?.problem != nil }
    }

    private var filesFooter: String {
        if places.isStillRefused {
            return String(localized: "Files still can't sign in. Sign in again here, or check the account on the server.")
        }
        if places.canTryAgain {
            return String(localized: "Signing in checks the password with the server, then Files uses it. Try Again has Files sign in and add the drives it couldn't. Neither opens Files.")
        }
        return String(localized: "Signing in checks the password with the server, then Files uses it. It doesn't open Files.")
    }

    /// Changes other apps saved into drives, which exist only on this iPhone.
    private var kept: [(drive: Connection, item: FilesNotes.Kept)] {
        connections.flatMap { drive in
            (places.notes[drive.id]?.kept ?? []).map { (drive, $0) }
        }
    }

    /// Every drive can be opened, even one that can't be reached with nothing on this phone: its
    /// folder says why, and has Check Again.
    @ViewBuilder
    private func row(for connection: Connection) -> some View {
        NavigationLink(value: Place(connection: connection, path: .root)) {
            rowLabel(for: connection)
        }
        .swipeActions {
            Button("Remove", role: .destructive) { remove(connection) }
            Button("Edit") { editing = connection }
            if places.notes[connection.id]?.problem != nil {
                Button("Sign In") { signingIn = connection }
                    .tint(.blue)
            }
        }
        .contextMenu {
            Button("Edit Drive…", systemImage: "pencil") { editing = connection }
            Button("Remove Drive", systemImage: "trash", role: .destructive) { remove(connection) }
        }
    }

    private func rowLabel(for connection: Connection) -> some View {
        let isOffline = drives.isOffline(connection)
        let pills = pills(for: connection)
        return Label {
            Text(connection.displayName)
            if isOffline {
                Group {
                    if let reason = drives.shortReason(for: connection) {
                        Text("Not connected: \(reason)")
                    } else {
                        Text("Not connected")
                    }
                }
                .foregroundStyle(.red)
            } else if !pills.isEmpty {
                DrivePills(pills: pills)
            } else {
                Text(subtitle(for: connection))
            }
        } icon: {
            if isOffline {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            } else {
                Image(systemName: connection.isEncrypted ? "lock" : "cloud")
            }
        }
        .foregroundStyle(isOffline ? .secondary : .primary)
    }

    var body: some View {
        NavigationStack(path: $trail) {
            List {
                Section {
                    if connections.isEmpty {
                        ContentUnavailableView(
                            "No Drives", systemImage: "cloud",
                            description: Text("Tap + to add one."))
                    }
                    ForEach(connections) { connection in
                        row(for: connection)
                    }
                } header: {
                    SectionLabel("Drives")
                }
                if !kept.isEmpty {
                    Section {
                        ForEach(kept, id: \.item.id) { entry in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(entry.item.name) in \(entry.drive.displayName)")
                                Text(entry.item.explanation)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } header: {
                        SectionLabel("Only on this iPhone")
                    }
                }
                if !needingSignIn.isEmpty || places.canTryAgain || places.isTryingAgain {
                    Section {
                        ForEach(needingSignIn) { connection in
                            Button {
                                signingIn = connection
                            } label: {
                                Text("Sign In to \(connection.displayName)…")
                                    .wholeRow()
                            }
                            .disabled(places.isTryingAgain)
                        }
                        if places.canTryAgain || places.isTryingAgain {
                            Button {
                                let drives = connections
                                Task { await places.tryAgain(drives: drives) }
                            } label: {
                                HStack(spacing: 8) {
                                    if places.isTryingAgain {
                                        ProgressView()
                                        Text("Trying…")
                                    } else {
                                        Text("Try Again in Files")
                                    }
                                }
                                .wholeRow()
                            }
                            .disabled(places.isTryingAgain)
                        }
                    } header: {
                        SectionLabel("Files")
                    } footer: {
                        Text(filesFooter)
                    }
                }
            }
            // Only a problem with this iPhone is shown here. A drive whose own server fails says
            // so on its own row, and in its folders.
            .safeAreaInset(edge: .top, spacing: 0) {
                if let warning = drives.appWideWarning.title {
                    OfflineBar(
                        reason: warning, isChecking: drives.isCheckingAgain,
                        checkAgain: { Task { await drives.checkAgain(drives.unreachableConnections, store: store) } },
                        openSettings: drives.appWideWarning.finding?.action?.opensSettings == true ? openAppSettings : nil)
                }
            }
            .refreshable {
                await drives.checkAgain(drives.unreachableConnections, store: store)
            }
            .navigationTitle("Drives")
            .navigationDestination(for: Place.self) { place in
                FolderView(place: place, store: store, drives: drives, trail: $trail) { editing = $0 }
            }
            .navigationDestination(isPresented: $isShowingSettings) {
                PhoneSettingsView(
                    canExport: !connections.isEmpty, drivesFileProblem: $drivesFileProblem,
                    exportDrives: {
                        Task {
                            drivesFileProblem = nil
                            if await DrivesFileAccess.confirmOwner() {
                                isExportingDrives = true
                            }
                        }
                    },
                    importDrives: {
                        drivesFileProblem = nil
                        isChoosingDrivesFile = true
                    },
                    showCloudAccess: { isShowingCloudAccess = true },
                    showAbout: { isShowingAbout = true })
            }
            .toolbar {
                // iOS puts a toolbar item in a round glass button the size of an icon, which
                // squeezed this to one letter. The pill keeps its own width and its own background.
                ToolbarItem(placement: .topBarLeading) {
                    Group {
                        if drives.appWideWarning.stopsEveryDrive {
                            StatusPill(text: "Not connected", color: .red)
                        } else {
                            StatusPill(text: "Ready", color: .green)
                        }
                    }
                    .fixedSize()
                }
                .sharedBackgroundVisibility(.hidden)
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add Drive", systemImage: "plus") {
                        isAdding = true
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Settings", systemImage: "gearshape") {
                        isShowingSettings = true
                    }
                }
            }
            .sheet(isPresented: $isAdding, onDismiss: reload) {
                AddDriveView(store: store)
            }
            .sheet(item: $signingIn) { connection in
                SignInView(connection: connection, store: store) {
                    drives.reconnect(connection)
                    let all = connections
                    // So Files hears at once, and the pill goes when it has signed in.
                    Task { await places.tryAgain(drives: all) }
                }
            }
            .sheet(item: $editing) { connection in
                EditDriveView(
                    connection: connection, store: store,
                    keptChanges: places.notes[connection.id]?.kept.count ?? 0,
                    saved: finishEdit)
            }
            .confirmationDialog(
                "Remove this drive?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                titleVisibility: .visible, presenting: removing
            ) { connection in
                Button("Remove Drive", role: .destructive) { remove(connection, confirmed: true) }
            } message: { connection in
                let count = places.notes[connection.id]?.kept.count ?? 0
                // One key, with a form for one change and one for more in the catalog.
                Text("\(count) changes saved into it by other apps are only on this iPhone. Removing the drive deletes them.")
            }
        }
        // These open from Settings, a page pushed over the list, so they hang on the stack itself,
        // which is always on screen. A drives file sent with AirDrop opens the import from here too.
        // After an uninstall the list is read again, and is empty.
        .sheet(isPresented: $isShowingAbout, onDismiss: reload) {
            AboutView(places: places, drives: drives)
        }
        .sheet(isPresented: $isExportingDrives) {
            ExportDrivesView(store: store, drives: connections)
        }
        .fileImporter(isPresented: $isChoosingDrivesFile, allowedContentTypes: [.drivesFile]) { result in
            do {
                importing = DrivesFileToImport(data: try DrivesFileAccess.read(result.get(), deletingCopy: false))
            } catch {
                drivesFileProblem = error.localizedDescription
            }
        }
        .sheet(item: $importing, onDismiss: reload) { file in
            ImportDrivesView(store: store, file: file) { updated in
                for connection in connections where updated.contains(connection.id) {
                    drives.reconnect(connection)
                }
                reload()
                if !updated.isEmpty {
                    let all = (try? store.connections()) ?? []
                    Task { await places.tryAgain(drives: all) }
                }
            }
        }
        .sheet(isPresented: $isShowingCloudAccess) {
            CloudAccessView()
        }
        .onAppear(perform: reload)
        // A drives file sent with AirDrop, or opened from Files. iOS hands over a copy.
        .onOpenURL { url in
            guard url.pathExtension == DrivesFile.fileExtension else { return }
            do {
                importing = DrivesFileToImport(data: try DrivesFileAccess.read(url, deletingCopy: true))
            } catch {
                drivesFileProblem = error.localizedDescription
            }
        }
        .onChange(of: scenePhase) {
            if scenePhase == .active {
                updatePlaces()
                // A switch in Settings, such as Local Network, may have changed while away.
                drives.checks.checkAgainOnNextFailure()
                drives.startRechecking(store: store)
            } else {
                // A drive that can't be reached is only tried again while the app is in front.
                drives.stopRechecking()
            }
        }
        .task {
            drives.startRechecking(store: store)
        }
    }

    private func reload() {
        connections = (try? store.connections()) ?? []
        updatePlaces()
    }

    /// CloudWanderer's page in Settings, with its Local Network, mobile data and Wi-Fi switches.
    private func openAppSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            openURL(url)
        }
    }

    /// Puts the drives in the Files app, or takes them away, to match the list here.
    private func updatePlaces() {
        let drives = connections
        Task { await places.refresh(drives: drives) }
    }

    /// On the iPhone a location can only be removed with everything in it, so a drive holding
    /// changes that exist nowhere else asks first.
    /// Finishes an edit the screen has saved. Open folders hold a copy of the old details, so the
    /// trail goes back to the drives.
    private func finishEdit(_ outcome: DriveEditOutcome) {
        trail = []
        switch outcome {
        case .updated(let connection, let signInChanged):
            drives.reconnect(connection)
            // The list again, which also renames the drive's place in Files.
            reload()
            if signInChanged {
                let all = connections
                Task { await places.tryAgain(drives: all) }
            }
        case .moved(let old, _):
            // The new drive is saved already. The old one goes as a removal does, its place in
            // Files first, and then the new one gets a place of its own.
            Task {
                await places.removeLocation(of: old)
                try? store.remove(id: old.id)
                drives.forget(old)
                reload()
            }
        }
    }

    private func remove(_ connection: Connection, confirmed: Bool = false) {
        if !confirmed, !(places.notes[connection.id]?.kept.isEmpty ?? true) {
            removing = connection
            return
        }
        removing = nil
        Task {
            // The location first, so Files isn't left asking for a password that's already gone.
            await places.removeLocation(of: connection)
            try? store.remove(id: connection.id)
            drives.forget(connection)
            reload()
        }
    }
}

/// Says where the person is, and goes back to any part of that in one tap, however deep they are.
struct LocationBar: View {
    @Binding var trail: [Place]

    var body: some View {
        ScrollViewReader { scroller in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Button("Drives") { trail = [] }
                    ForEach(Array(trail.enumerated()), id: \.offset) { index, place in
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        if index == trail.count - 1 {
                            Text(place.title)
                                .fontWeight(.semibold)
                                .id("here")
                        } else {
                            Button(place.title) { trail = Array(trail.prefix(index + 1)) }
                        }
                    }
                }
                .font(.subheadline)
                .padding(.horizontal, 16)
                .frame(minHeight: 44)
            }
            .onChange(of: trail.count, initial: true) {
                scroller.scrollTo("here", anchor: .trailing)
            }
        }
        .background(.bar)
    }
}

struct FolderView: View {
    let place: Place
    let store: DriveStore
    let drives: OpenDrives
    @Binding var trail: [Place]
    /// Opens the drive's settings, for a finding fixed by changing its address or port.
    let edit: (Connection) -> Void

    @Environment(\.openURL) private var openURL
    @State private var engine: RemoteEngine?
    @State private var items: [RemoteItem] = []
    /// One choice for every folder, kept between launches.
    @AppStorage("folderOrder") private var order: FolderOrder = .nameAscending
    /// Off unless asked for, so the order chosen applies to folders too.
    @AppStorage("foldersFirst") private var foldersFirst = false
    @AppStorage("showsHidden") private var showsHidden = false
    @State private var isShowingOptions = false
    @State private var isLoading = true
    @State private var problem: String?
    /// The server couldn't be reached and nothing from here is on this phone.
    @State private var cannotConnect = false

    private var isOffline: Bool {
        drives.isOffline(place.connection)
    }

    private func checkAgain() {
        Task { await drives.checkAgain([place.connection], store: store) }
    }

    /// What the last check of this drive found, while it can't connect.
    private var finding: ConnectionFinding? {
        isOffline ? drives.checks.findings[place.connection.id] : nil
    }

    @ViewBuilder
    private func folderRow(_ item: RemoteItem) -> some View {
        // Grayed out only if there's nothing to show for it on this phone.
        let isAvailable = !isOffline || drives.library.hasListing(of: item.path, drive: place.connection.id)
        NavigationLink(value: Place(connection: place.connection, path: item.path)) {
            Label(item.path.name, systemImage: "folder")
        }
        .disabled(!isAvailable)
        .opacity(isAvailable ? 1 : 0.4)
    }

    var body: some View {
        let shown = order.sorted(FolderOrder.shown(items, showsHidden: showsHidden), foldersFirst: foldersFirst)
        List(shown, id: \.path) { item in
            switch item.kind {
            case .directory:
                folderRow(item)
            case .file:
                FileRow(
                    engine: engine, item: item, connection: place.connection,
                    library: drives.library, isOffline: isOffline)
            }
        }
        .refreshable {
            await load()
        }
        .overlay {
            if cannotConnect {
                ContentUnavailableView {
                    Label("Couldn't Connect", systemImage: "cloud.slash")
                } description: {
                    VStack {
                        Text(verbatim: drives.reason(for: place.connection) ?? problem ?? "")
                        if let finding {
                            CheckedLine(checked: finding.checked)
                        }
                    }
                } actions: {
                    // One under the other: what fixes it, then checking again.
                    if finding?.action?.opensSettings == true, let url = URL(string: UIApplication.openSettingsURLString) {
                        Button("Open Settings") { openURL(url) }
                            .buttonStyle(.borderedProminent)
                    } else if finding?.action == .editDrive {
                        Button("Edit Drive…") { edit(place.connection) }
                            .buttonStyle(.borderedProminent)
                    }
                    CheckAgainButton(isChecking: drives.isCheckingAgain, action: checkAgain)
                        .buttonStyle(.bordered)
                }
            } else if let problem {
                ContentUnavailableView("Couldn't Connect", systemImage: "cloud.slash", description: Text(problem))
            } else if isLoading {
                ProgressView()
            } else if FolderOrder.shown(items, showsHidden: true).isEmpty {
                ContentUnavailableView("Empty Folder", systemImage: "folder")
            } else if shown.isEmpty {
                ContentUnavailableView(
                    "Only Hidden Items", systemImage: "eye.slash",
                    description: Text("Turn on Show hidden files to see them."))
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                LocationBar(trail: $trail)
                // This drive's own bar, unless the message in the middle already says it.
                if isOffline, !cannotConnect {
                    OfflineBar(
                        reason: drives.reason(for: place.connection), checked: finding?.checked,
                        isChecking: drives.isCheckingAgain, checkAgain: checkAgain)
                }
            }
        }
        .navigationTitle(place.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                // A sheet, not a menu: iOS draws a menu's switches as checkmarks.
                Button("Sort and View Options", systemImage: "arrow.up.arrow.down") {
                    isShowingOptions = true
                }
            }
        }
        .sheet(isPresented: $isShowingOptions) {
            FolderOptionsView(order: $order, foldersFirst: $foldersFirst, showsHidden: $showsHidden)
        }
        .task(id: drives.retry) {
            await load()
        }
    }

    /// Shows what's known first, so a slow or missing connection never means a blank screen.
    private func load() async {
        let drive = place.connection.id
        let kept = drives.library.listing(of: place.path, drive: drive)
        if let kept, items.isEmpty {
            items = kept
            isLoading = false
        }
        do {
            let opened = try await drives.engine(for: place.connection, store: store)
            let fresh = try await opened.list(place.path)
            engine = opened
            items = fresh
            problem = nil
            cannotConnect = false
            drives.noteReachable(place.connection)
            try? drives.library.save(listing: fresh, of: place.path, drive: drive)
        } catch let error as RemoteError where error.scope == .connection {
            drives.noteUnreachable(place.connection, because: error)
            engine = nil
            if kept == nil {
                // Words of its own, until a check says which part failed.
                problem = error.localizedDescription
                cannotConnect = ConnectionFinding.isFor(error)
            }
        } catch {
            if !Task.isCancelled, !(error is CancellationError) {
                AppLog.record("\(place.connection.displayName): a folder didn't list: \(Diagnostics.kind(of: error))")
                if kept == nil {
                    problem = error.localizedDescription
                }
            }
        }
        isLoading = false
    }
}

struct FileRow: View {
    let engine: RemoteEngine?
    let item: RemoteItem
    let connection: Connection
    let library: OfflineLibrary
    let isOffline: Bool

    private var drive: UUID { connection.id }

    @State private var kept: URL?
    @State private var download: Task<Void, Never>?
    @State private var watch: DownloadWatch?
    @State private var isSharing = false
    @State private var problem: String?

    /// A file on this phone always works, and only the rest gray out with the connection.
    private var isAvailable: Bool {
        !isOffline || kept != nil
    }

    /// What's kept here is older than what the server lists, so exporting it would quietly give
    /// someone old bytes under the new size.
    private var isOutdated: Bool {
        kept != nil && library.isOutdated(item.path, drive: drive, serverVersion: item.versionID)
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(FlattenedPackage.shownName(item.path.name))
                if download != nil, let watch {
                    DownloadLine(progress: watch.progress)
                } else if let problem {
                    Text(problem)
                        .font(.caption)
                        .foregroundStyle(.red)
                } else if !isAvailable {
                    Text("Not on this iPhone")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if isOutdated {
                    Text("Newer version on the server")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if FlattenedPackage.isFlattened(item.path.name) {
                    // Only macOS can turn it back into a document, so a copy here wouldn't open.
                    Text("Open this on a Mac")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if item.ownModified != nil || item.size != nil {
                    HStack {
                        // Only the file's own date, from its details. The server's is when the file
                        // arrived there, which isn't the file's.
                        if let own = item.ownModified {
                            Text(own.formatted(.dateTime.day().month(.abbreviated).year().hour().minute()))
                        }
                        Spacer(minLength: 8)
                        if let size = item.size {
                            Text(size.formatted(.byteCount(style: .file)))
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
            }
            // Fills the row, so the bar under the name has room.
            .frame(maxWidth: .infinity, alignment: .leading)
            if let download {
                Button("Cancel", systemImage: "xmark.circle") { download.cancel() }
                    .labelStyle(.iconOnly)
            } else if isOutdated && !isOffline {
                Button("Download Newer Version", systemImage: "arrow.down.circle", action: start)
                    .labelStyle(.iconOnly)
            } else if kept != nil {
                // The share sheet includes Save to Files.
                Button("Export", systemImage: "square.and.arrow.up") { isSharing = true }
                    .labelStyle(.iconOnly)
            } else if isAvailable {
                Button("Download", systemImage: "arrow.down.circle", action: start)
                    .labelStyle(.iconOnly)
            }
        }
        .opacity(isAvailable ? 1 : 0.4)
        .buttonStyle(.borderless)
        .swipeActions {
            if kept != nil {
                Button("Remove Download", role: .destructive) {
                    library.removeDownload(of: item.path, drive: drive)
                    kept = nil
                }
            }
        }
        .sheet(isPresented: $isSharing) {
            if let kept {
                ShareSheet(file: kept)
            }
        }
        .onAppear {
            kept = library.download(of: item.path, drive: drive)
        }
    }

    private func start() {
        guard let engine else { return }
        problem = nil
        let started = Date()
        let watch = DownloadWatch(total: item.size)
        self.watch = watch
        download = Task {
            var incoming: URL?
            do {
                let file = try library.temporaryFile(drive: drive)
                incoming = file
                let fetched = try await TransferContext.$progress.withValue({ watch.hear(bytes: $0) }) {
                    try await engine.verifiedDownload(item.path, to: file) { watch.hear($0) }
                }
                try Task.checkCancellation()
                OfflineLibrary.stamp(file, with: fetched)
                kept = try library.keep(file, as: item.path, drive: drive, version: fetched.versionID)
                AppLog.download(on: connection, progress: watch.progress, started: started, error: nil)
            } catch {
                AppLog.download(
                    on: connection, progress: watch.progress, started: started,
                    error: Task.isCancelled ? CancellationError() : error)
                if let incoming { try? FileManager.default.removeItem(at: incoming) }
                if !Task.isCancelled { problem = await ConnectionChecks.explain(error, for: connection, device: .iPhone) }
            }
            download = nil
            self.watch = nil
        }
    }
}
