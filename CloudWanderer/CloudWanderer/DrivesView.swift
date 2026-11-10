// Apache 2 license - developer@infinitecontext.com

import CloudCore
import CloudDesign
import RemoteEngine
import SwiftUI

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

    init() {
        library.clearAbandoned()
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
        if shouldRetry {
            unreachable = []
            engines = [:]
            retry += 1
        }
    }

    var isAnythingOffline: Bool {
        !isNetworkUp || !unreachable.isEmpty
    }

    func isOffline(_ connection: Connection) -> Bool {
        !isNetworkUp || unreachable.contains(connection.id)
    }

    func noteReachable(_ connection: Connection) {
        if unreachable.remove(connection.id) != nil {
            AppLog.record("\(connection.displayName): connected again")
        }
    }

    /// Logged only when it changes, so a folder opened again while offline adds nothing.
    func noteUnreachable(_ connection: Connection, because error: Error) {
        if unreachable.insert(connection.id).inserted {
            AppLog.record("\(connection.displayName): can't connect: \(Diagnostics.kind(of: error))")
        }
        engines[connection.id] = nil
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

/// The red warning shown while a drive can't be reached.
struct OfflineBar: View {
    /// What to check, when there's more to say.
    var hint: String?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Not connected")
                    .fontWeight(.semibold)
                Text("Files on this iPhone are still available.")
                    .font(.footnote)
                if let hint {
                    Text(hint)
                        .font(.footnote)
                }
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        // Darker than system red, so white text stays readable on it.
        .background(Color(red: 0.72, green: 0.11, blue: 0.09))
    }
}

extension View {
    /// Fills the row of a list, so the whole row takes the tap, not only the words.
    fileprivate func wholeRow() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
    }
}

/// Why the Files app can't use a drive, a word or two each. Side by side when they fit, and one
/// under the other on a narrow iPhone.
struct DrivePills: View {
    struct Pill: Hashable {
        let text: String
        let color: Color
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
    /// A drive whose removal would delete changes kept only on this iPhone, waiting for a yes.
    @State private var removing: Connection?
    @State private var signingIn: Connection?
    @State private var editing: Connection?
    @Environment(\.scenePhase) private var scenePhase

    /// Encrypted drives say so in a pill instead.
    private func kind(of connection: Connection) -> String {
        if case .sftp = connection.endpoint { return "SFTP" }
        return "WebDAV"
    }

    /// The kind of drive, or why it isn't in the Files app when someone would look for it there.
    private func subtitle(for connection: Connection) -> String {
        if let problem = places.problems[connection.id] {
            return "Not in Files: \(problem)"
        }
        if places.switchedOff.contains(connection.id) {
            return "Off in the Files app. Turn it on there, under Locations."
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
            return "Files still can't sign in. Sign in again here, or check the account on the server."
        }
        if places.canTryAgain {
            return "Signing in checks the password with the server, then Files uses it. Try Again has Files sign in and add the drives it couldn't. Neither opens Files."
        }
        return "Signing in checks the password with the server, then Files uses it. It doesn't open Files."
    }

    /// Changes other apps saved into drives, which exist only on this iPhone.
    private var kept: [(drive: Connection, item: FilesNotes.Kept)] {
        connections.flatMap { drive in
            (places.notes[drive.id]?.kept ?? []).map { (drive, $0) }
        }
    }

    private var isTailnetDriveOffline: Bool {
        connections.contains { $0.usesTailnet && drives.isOffline($0) }
    }

    /// An offline drive can still be opened if something from it is on this phone.
    private func canOpen(_ connection: Connection) -> Bool {
        !drives.isOffline(connection) || drives.library.hasListing(of: .root, drive: connection.id)
    }

    @ViewBuilder
    private func row(for connection: Connection) -> some View {
        Group {
            if canOpen(connection) {
                NavigationLink(value: Place(connection: connection, path: .root)) {
                    rowLabel(for: connection)
                }
            } else {
                // Not a disabled link: a drive whose server moved is the one that most needs
                // editing, and a disabled row takes no swipe.
                rowLabel(for: connection)
            }
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
                Text(connection.usesTailnet ? "Not connected. Check Tailscale." : "Not connected")
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
                Section {
                    HStack(spacing: 8) {
                        Tile("CloudAccess for Mac", symbol: "laptopcomputer") {
                            isShowingCloudAccess = true
                        }
                        Tile("About", symbol: "info.circle") {
                            isShowingAbout = true
                        }
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if drives.isAnythingOffline {
                    OfflineBar(hint: isTailnetDriveOffline ? Tailnet.hint : nil)
                }
            }
            .navigationTitle("Drives")
            .navigationDestination(for: Place.self) { place in
                FolderView(place: place, store: store, drives: drives, trail: $trail)
            }
            .toolbar {
                // iOS puts a toolbar item in a round glass button the size of an icon, which
                // squeezed this to one letter. The pill keeps its own width and its own background.
                ToolbarItem(placement: .topBarLeading) {
                    StatusPill(
                        text: drives.isAnythingOffline ? "Not connected" : "Ready",
                        color: drives.isAnythingOffline ? .red : .green)
                    .fixedSize()
                }
                .sharedBackgroundVisibility(.hidden)
                ToolbarItem(placement: .primaryAction) {
                    Button("Add Drive", systemImage: "plus") {
                        isAdding = true
                    }
                }
            }
            .sheet(isPresented: $isAdding, onDismiss: reload) {
                AddDriveView(store: store)
            }
            .sheet(isPresented: $isShowingAbout) {
                AboutView()
            }
            .sheet(isPresented: $isShowingCloudAccess) {
                CloudAccessView()
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
                Text(count == 1
                    ? "1 change saved into it by another app is only on this iPhone. Removing the drive deletes it."
                    : "\(count) changes saved into it by other apps are only on this iPhone. Removing the drive deletes them.")
            }
        }
        .onAppear(perform: reload)
        .onChange(of: scenePhase) {
            if scenePhase == .active {
                updatePlaces()
            }
        }
    }

    private func reload() {
        connections = (try? store.connections()) ?? []
        updatePlaces()
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

    private var isOffline: Bool {
        drives.isOffline(place.connection)
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
            if let problem {
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
                if isOffline {
                    OfflineBar(hint: place.connection.usesTailnet ? Tailnet.hint : nil)
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
            drives.noteReachable(place.connection)
            try? drives.library.save(listing: fresh, of: place.path, drive: drive)
        } catch let error as RemoteError where error.scope == .connection {
            drives.noteUnreachable(place.connection, because: error)
            engine = nil
            if kept == nil {
                problem = Tailnet.explain(error, for: place.connection.endpoint)
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
    private var endpoint: Connection.Endpoint { connection.endpoint }

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
                if !Task.isCancelled { problem = Tailnet.explain(error, for: endpoint) }
            }
            download = nil
            self.watch = nil
        }
    }
}
