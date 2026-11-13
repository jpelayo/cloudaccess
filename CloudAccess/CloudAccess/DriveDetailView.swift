// Apache 2 license - developer@infinitecontext.com

import CloudCore
import CloudDesign
import CoreImage.CIFilterBuiltins
import RemoteEngine
import SwiftUI
import SyncCore
import UniformTypeIdentifiers

extension UUID: @retroactive Identifiable {
    public var id: UUID { self }
}

/// Text to save, with an identity so a view can present a save panel for it.
struct TextFile: Identifiable {
    let id = UUID()
    let text: String
}

private struct PlainTextDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.plainText]
    let text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

extension View {
    /// Asks where to save the text whenever `file` is set.
    /// - Parameter saved: Runs once the file is really written, and not if it's cancelled.
    func savesText(
        _ file: Binding<TextFile?>, named name: String, saved: @escaping () -> Void = {}
    ) -> some View {
        fileExporter(
            isPresented: Binding {
                file.wrappedValue != nil
            } set: { isShown in
                if !isShown { file.wrappedValue = nil }
            },
            document: file.wrappedValue.map { PlainTextDocument(text: $0.text) },
            contentType: .plainText,
            defaultFilename: name
        ) { result in
            file.wrappedValue = nil
            if case .success = result {
                saved()
            }
        }
    }
}


/// One drive's settings, on pages that each fit the window.
struct DriveDetailView: View {
    enum Page: String, CaseIterable {
        case general = "General"
        case advanced = "Advanced"
        case deleted = "Deleted Files"
        case information = "Information"

        /// The name on the page's tab, in the language shown. The raw value stays English.
        var title: LocalizedStringKey {
            switch self {
            case .general: "General"
            case .advanced: "Advanced"
            case .deleted: "Deleted Files"
            case .information: "Information"
            }
        }
    }

    @Environment(Drives.self) private var drives
    @Environment(\.dismiss) private var dismiss

    let connection: Connection

    @State private var folders: [SyncItem] = []
    @State private var folderFilter = ""
    @State private var page: Page
    @State private var isShowingCode = false
    @State private var isConfirmingRemove = false
    @State private var isConfirmingReset = false
    @State private var isConfirmingRetire = false
    @State private var recoveryKit: TextFile?
    @State private var isWorking = false
    /// What the spinner beside Done says, for work that takes a while.
    @State private var activity: LocalizedStringKey?
    @State private var problem: String?
    @State private var message: String?
    @State private var hasUnsavedEdits = false
    @State private var saveRequests = 0
    /// What the server's `.cloudmount` folder holds, looked up when the drive stops using it.
    @State private var controlFolder: RemoteEngine.ControlFolder?
    @State private var hasCheckedControlFolder = false
    @State private var controlFolderFailed = false
    @State private var isOfferingCleanUp = false
    @State private var hasLoadedFolders = false

    init(connection: Connection, startingPage: Page = .general) {
        self.connection = connection
        _page = State(initialValue: startingPage)
    }

    /// The saved version, because this view can outlive the copy it was given.
    private var current: Connection {
        drives.connections.first { $0.id == connection.id } ?? connection
    }

    private func setting<Value>(_ path: WritableKeyPath<DriveSettings, Value>) -> Binding<Value> {
        Binding {
            current.settings[keyPath: path]
        } set: { value in
            var changed = current
            changed.settings[keyPath: path] = value
            drives.update(changed)
        }
    }

    /// A change of mode applies straight away. Leaving Safe offers to remove what the drive no
    /// longer needs on the server, and never removes it without asking.
    private var mode: Binding<DriveMode> {
        Binding {
            current.settings.mode
        } set: { newMode in
            var changed = current
            changed.settings.mode = newMode
            drives.update(changed)
            Task { await lookAtControlFolder(offering: !newMode.usesControlFolder) }
        }
    }

    /// Only an SFTP drive that's left Safe mode is offered the clean-up.
    private var offersControlFolderCleanUp: Bool {
        guard case .sftp = current.endpoint else { return false }
        return !current.settings.mode.usesControlFolder && !current.serverIsReadOnly
    }

    private func lookAtControlFolder(offering: Bool) async {
        guard offersControlFolderCleanUp else {
            controlFolder = nil
            return
        }
        hasCheckedControlFolder = false
        do {
            controlFolder = try await drives.controlFolder(of: current)
            controlFolderFailed = false
        } catch {
            controlFolder = nil
            controlFolderFailed = true
        }
        hasCheckedControlFolder = true
        if offering, controlFolder?.hasRemovable == true {
            isOfferingCleanUp = true
        }
    }

    /// Whole sentences, each translated by itself, and only the ones that apply.
    private func cleanUpNote(_ found: RemoteEngine.ControlFolder) -> String {
        var sentences = [
            String(localized: "CloudAccess keeps locks, uploads in progress and deleted files there for Safe mode.")
        ]
        if found.trashItems > 0 {
            sentences.append(String(localized: "\(found.trashItems) deleted files kept there will be gone for good."))
        }
        if found.safeDevices > 0 {
            sentences.append(String(localized: "\(found.safeDevices) other devices use this drive in Safe mode, and will make the folder again."))
        }
        if found.hasVault {
            sentences.append(String(localized: "The encryption marker stays, because the drive can't be opened without it."))
        }
        if found.busy {
            sentences.append(String(localized: "A device in Safe mode looks to be saving now, so this may have to wait."))
        }
        return sentences.joined(separator: " ")
    }

    /// A drive can have a thousand folders, so a filter appears once the list is long.
    private static let filterThreshold = 10

    private var visibleFolders: [SyncItem] {
        guard !folderFilter.isEmpty else { return folders }
        return folders.filter { $0.name.localizedCaseInsensitiveContains(folderFilter) }
    }

    /// Kept folders come first, so they aren't lost in a long list. This runs when the list
    /// loads, not on each change, so a row doesn't jump away from under the pointer.
    private func loadFolders() async {
        folders = await drives.topFolders(of: current).sorted { first, second in
            if first.isPinned != second.isPinned { return first.isPinned }
            return first.name.localizedStandardCompare(second.name) == .orderedAscending
        }
        hasLoadedFolders = true
    }

    private func pinned(_ folder: SyncItem) -> Binding<Bool> {
        Binding {
            folders.first { $0.id == folder.id }?.isPinned ?? folder.isPinned
        } set: { isPinned in
            if let index = folders.firstIndex(where: { $0.id == folder.id }) {
                folders[index].isPinned = isPinned
            }
            Task { await drives.setPinned(folder, in: current, isPinned: isPinned) }
        }
    }

    /// The tabs and Done stay where they are, and only the page between them scrolls, when it's
    /// taller than the room. The sheet's size never changes, whichever page shows or loads.
    var body: some View {
        SheetPage(height: Pane.driveHeight) {
            VStack(alignment: .leading, spacing: 10) {
                // The Information page explains it in full, so the other pages only name it, once.
                if drives.status(of: current) == .offline, page != .information {
                    let offline = drives.offlineStatus(of: current)
                    Label(offline.title, systemImage: offline.symbol)
                        .foregroundStyle(offline.tone.color)
                        .lineLimit(1)
                }
                Picker("Page", selection: $page) {
                    ForEach(Page.allCases, id: \.self) { page in
                        Text(page.title)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                // Each page is rebuilt when it's shown, so leaving this one would drop the edit.
                .disabled(hasUnsavedEdits || isWorking)
            }
        } content: {
            // A change made while the drive is being removed would save it back.
            Group {
                switch page {
                case .general:
                    general
                case .advanced:
                    advanced
                case .deleted:
                    TrashView(connection: current)
                case .information:
                    DriveInformationView(connection: current) { page = .general }
                }
            }
            .disabled(isWorking)
        } footer: {
            footer
        }
        .task {
            await loadFolders()
        }
        // Removed from somewhere else, such as an uninstall. Its own removal closes it at the end.
        .onChange(of: drives.connections.contains { $0.id == connection.id }) { _, isSaved in
            if !isSaved, !isWorking {
                dismiss()
            }
        }
        .sheet(isPresented: $isShowingCode) {
            ConnectionCodeView(connection: current, signsInWithKey: drives.signsInWithKey(current))
                .presentationSizing(.fitted)
        }
        .savesText($recoveryKit, named: "\(connection.displayName) Recovery Kit.txt")
        .confirmationDialog(
            "Remove \(connection.displayName)?", isPresented: $isConfirmingRemove
        ) {
            Button("Remove", role: .destructive) {
                perform("Removing the drive…") { try await drives.remove(current); dismiss() }
            }
        } message: {
            removeMessage
        }
        .confirmationDialog(
            "Reset \(connection.displayName)?", isPresented: $isConfirmingReset
        ) {
            Button("Reset", role: .destructive) {
                perform("Resetting the drive…") { try await drives.reset(current); dismiss() }
            }
        } message: {
            Text("The drive is removed and added again. Files that haven't uploaded are kept, and Settings shows where.")
        }
        .task(id: current.settings.mode) {
            await lookAtControlFolder(offering: false)
        }
        .confirmationDialog(
            "Remove CloudAccess's folder from the server?", isPresented: $isOfferingCleanUp,
            presenting: controlFolder
        ) { _ in
            Button("Remove", role: .destructive) {
                perform {
                    let result = try await drives.cleanControlFolder(of: current)
                    controlFolder = nil
                    message = result.hasVault
                        ? String(localized: "Removed. The encryption marker stayed, because the drive needs it.")
                        : String(localized: "Removed. Nothing of CloudAccess's is left on the server.")
                }
            }
            Button("Keep", role: .cancel) {}
        } message: { found in
            Text(cleanUpNote(found))
        }
        .confirmationDialog(
            "Retire this encrypted drive?", isPresented: $isConfirmingRetire
        ) {
            Button("Retire", role: .destructive) {
                perform {
                    try await drives.retireVault(of: current)
                    message = String(localized: "Retired. Every device stops writing here when it next checks.")
                }
            }
        } message: {
            Text("Do this after moving to a new drive with a new password. No device can write here afterwards, and this can't be undone.")
        }
    }

    /// What's happening, and Done, which close the sheet.
    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let message {
                Text(message)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let problem {
                Text(problem)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                    if let activity {
                        Text(activity)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if hasUnsavedEdits {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("Save") { saveRequests += 1 }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    /// One whole message either way, so each reads right in every language.
    private var removeMessage: Text {
        let count = drives.unsentCount(of: connection)
        guard count > 0 else { return Text("Everything on the server stays there.") }
        return Text("\(count) files haven't uploaded yet. They'll be kept on this Mac, and Settings shows where. Everything on the server stays there.")
    }

    private var general: some View {
        VStack(alignment: .leading, spacing: Design.sectionGap) {
            SettingsSection("Connection") {
                ConnectionEditor(
                    connection: current, saveRequests: saveRequests, hasUnsavedEdits: $hasUnsavedEdits
                ) {
                    dismiss()
                }
                SettingRow("Set up CloudWanderer") {
                    Button("Show QR Code…", systemImage: "qrcode") { isShowingCode = true }
                        .buttonStyle(.pill)
                }
            }
            SettingsSection("Locally stored file cache") {
                PickerRow("Unused files", selection: setting(\.removeLocalCopyAfter)) {
                    Text("Clear cache right away").tag(TimeInterval?.some(0))
                    Text("Clear cache after 1 hour").tag(TimeInterval?.some(3600))
                    Text("Clear cache after 1 day").tag(TimeInterval?.some(86_400))
                    Text("Clear cache after 1 week").tag(TimeInterval?.some(604_800))
                    Text("Keep in cache").tag(TimeInterval?.none)
                }
                PickerRow("Cache size limit", selection: setting(\.sizeLimit)) {
                    Text("1 GB").tag(Int64?.some(1_000_000_000))
                    Text("10 GB").tag(Int64?.some(10_000_000_000))
                    Text("50 GB").tag(Int64?.some(50_000_000_000))
                    Text("No limit").tag(Int64?.none)
                }
                if let cached = drives.cachedBytes[connection.id] {
                    storageUse(cached)
                }
            }
        }
    }

    @ViewBuilder
    private func storageUse(_ cached: Int64) -> some View {
        let used = String(localized: "On this Mac \(cached.formatted(.byteCount(style: .file)))")
        if let limit = current.settings.sizeLimit, limit > 0 {
            UsageBar(
                share: Double(cached) / Double(limit), used: used,
                limit: String(localized: "Limit \(limit.formatted(.byteCount(style: .file)))"))
        } else {
            SettingRow("Using now") {
                Text(cached.formatted(.byteCount(style: .file)))
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The list keeps its full height while it loads, so nothing under it moves when it arrives.
    private var keepDownloaded: some View {
        VStack(alignment: .leading, spacing: Design.labelGap) {
            SectionLabel("Keep downloaded")
            if folders.count > Self.filterThreshold {
                TextField("Filter folders", text: $folderFilter)
                    .textFieldStyle(.roundedBorder)
            }
            BoundedList(
                rows: visibleFolders.count, rowHeight: RowHeight.single, visibleRows: 4, reserves: !hasLoadedFolders
            ) {
                if !hasLoadedFolders {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, minHeight: RowHeight.single)
                } else if folders.isEmpty {
                    Text("No folders yet.")
                        .foregroundStyle(.secondary)
                        .frame(height: RowHeight.single)
                }
                ForEach(visibleFolders, id: \.id) { folder in
                    ListRow(height: RowHeight.single) {
                        Text(folder.name)
                    } controls: {
                        RowSwitch(label: "Keep \(folder.name) downloaded", isOn: pinned(folder))
                    }
                }
            }
            Text("These folders and everything in them stay on this Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var advanced: some View {
        VStack(alignment: .leading, spacing: Design.sectionGap) {
            keepDownloaded
            SettingsSection("Behaviour") {
                if current.serverIsReadOnly {
                    SettingRow("Mode") {
                        Text("Read-only, set by the server")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    PickerRow(
                        "Mode", selection: mode, caption: Text(current.settings.mode.explanation),
                        captionColor: current.settings.mode == .unsafe ? .orange : .secondary
                    ) {
                        ForEach(DriveMode.available(for: current.endpoint), id: \.self) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                }
                PickerRow("Thumbnails", selection: setting(\.thumbnailLimit)) {
                    Text("Files under 20 MB").tag(Int64?.some(20_000_000))
                    Text("Files under 100 MB").tag(Int64?.some(100_000_000))
                    Text("Off").tag(Int64?.none)
                }
                PickerRow("Keep free on disk", selection: setting(\.diskReserve)) {
                    Text("1 GB").tag(Int64?.some(1_000_000_000))
                    Text("5 GB").tag(Int64?.some(5_000_000_000))
                    Text("20 GB").tag(Int64?.some(20_000_000_000))
                    Text("Don't check").tag(Int64?.none)
                }
                PickerRow("Uploads at once", selection: setting(\.uploadsAtOnce)) {
                    Text("1").tag(1)
                    Text("2").tag(2)
                    Text("4").tag(4)
                    Text("8").tag(8)
                }
                PickerRow("Check recent folders", selection: setting(\.recentFolderInterval)) {
                    Text("Every minute").tag(TimeInterval(60))
                    Text("Every 5 minutes").tag(TimeInterval(300))
                    Text("Every 15 minutes").tag(TimeInterval(900))
                }
                PickerRow("Check other folders", selection: setting(\.otherFolderInterval)) {
                    Text("Every 30 minutes").tag(TimeInterval(1800))
                    Text("Every hour").tag(TimeInterval(3600))
                    Text("Every 6 hours").tag(TimeInterval(21_600))
                }
            }
            SettingsSection("Maintenance") {
                SettingRow("Check the drive again") {
                    Button("Repair Drive") {
                        perform {
                            try await drives.repair(current)
                            message = String(localized: "Repaired. macOS is checking the drive again.")
                        }
                    }
                    .buttonStyle(.pill)
                }
                SettingRow("Remove it and add it back") {
                    Button("Reset Drive…") { isConfirmingReset = true }
                        .buttonStyle(.destructivePill)
                }
                if connection.isEncrypted {
                    SettingRow("Reach your files without this app") {
                        Button("Save Recovery Kit…") {
                            perform { recoveryKit = TextFile(text: try await drives.recoveryKit(for: current)) }
                        }
                        .buttonStyle(.pill)
                    }
                    if current.writesControlFolder {
                        SettingRow("Stop writing to this drive for good") {
                            Button("Retire This Drive…") { isConfirmingRetire = true }
                                .buttonStyle(.destructivePill)
                        }
                    }
                }
                if offersControlFolderCleanUp {
                    SettingRow("Hidden .cloudmount folder on the server") {
                        controlFolderControl
                    }
                }
                // Here, not beside Done, where one slip could reach it.
                SettingRow("Take this drive off this Mac") {
                    Button("Remove Drive…", role: .destructive) { isConfirmingRemove = true }
                        .buttonStyle(.destructivePill)
                }
            }
            .disabled(isWorking)
        }
    }

    /// The row is there from the start, so nothing appears under the pointer when the server answers.
    @ViewBuilder
    private var controlFolderControl: some View {
        if !hasCheckedControlFolder {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Checking…")
                    .foregroundStyle(.secondary)
            }
        } else if controlFolder?.hasRemovable == true {
            Button("Remove Folder…") { isOfferingCleanUp = true }
                .buttonStyle(.destructivePill)
        } else if controlFolderFailed {
            Text("Couldn't check")
                .foregroundStyle(.secondary)
        } else {
            Text("Nothing to remove")
                .foregroundStyle(.secondary)
        }
    }

    private func perform(
        _ activity: LocalizedStringKey? = nil, _ work: @escaping @MainActor () async throws -> Void
    ) {
        isWorking = true
        self.activity = activity
        problem = nil
        message = nil
        Task {
            defer {
                isWorking = false
                self.activity = nil
            }
            do {
                try await work()
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}

/// The code CloudWanderer scans. It holds no passwords, so a photo of it can't open the drive.
struct ConnectionCodeView: View {
    @Environment(\.dismiss) private var dismiss

    let connection: Connection
    let signsInWithKey: Bool

    private var code: CGImage? {
        let setup = ConnectionSetup(connection: connection, signsInWithKey: signsInWithKey)
        guard let text = try? setup.encoded() else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let image = filter.outputImage else { return nil }
        let scaled = image.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        return CIContext().createCGImage(scaled, from: scaled.extent)
    }

    var body: some View {
        VStack(spacing: 16) {
            Text(connection.displayName)
                .font(.headline)
            if let code {
                Image(decorative: code, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 280, height: 280)
            } else {
                Text("This drive's code can't be made.")
                    .foregroundStyle(.secondary)
            }
            Text("Scan this in CloudWanderer on your iPhone. It holds no passwords, so you'll enter those there.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(24)
        .frame(width: 340)
    }
}

/// What's been deleted, which stays on the server until its retention period ends.
struct TrashView: View {
    @Environment(Drives.self) private var drives

    let connection: Connection

    @State private var entries: [RemoteEngine.TrashEntry] = []
    @State private var retention: Int?
    @State private var isLoading = true
    @State private var problem: String?
    @State private var filtersFiles = true
    @State private var search = ""
    @State private var shortening: TrashRetention.Choice?
    /// The entries ticked to delete now, by ID.
    @State private var chosen: Set<String> = []
    @State private var isConfirmingPurge = false
    @State private var isPurging = false
    @State private var purgeNote: String?

    /// A search field appears once the list is long, as a filter does for pinned folders.
    private static let searchThreshold = 10
    /// A time this short takes things off the list while it's open. Reading the list costs two
    /// requests an entry, so it isn't read again for anything longer.
    private static let refreshesUpTo = 3_600
    private static let refreshInterval = Duration.seconds(30)

    private var fileCount: Int {
        entries.count(where: { !$0.isDirectory })
    }

    private var filterNote: String {
        guard filtersFiles else { return String(localized: "Showing deleted folders and files.") }
        return String(localized: "Showing deleted folders only. \(fileCount) deleted files are hidden.")
    }

    /// Folders by default. Single files can run to thousands, so they're counted until asked for.
    private var visibleEntries: [RemoteEngine.TrashEntry] {
        entries.filter { entry in
            (!filtersFiles || entry.isDirectory)
                && (search.isEmpty || entry.originalPath.localizedCaseInsensitiveContains(search))
        }
    }

    /// A longer time can't lose anything. A shorter one removes what's already past it, on every
    /// device and for good, so it's asked about first.
    private var retentionChoice: Binding<Int> {
        Binding {
            retention ?? TrashRetention.defaultSeconds
        } set: { seconds in
            guard let current = retention, seconds != current else { return }
            if seconds < current {
                shortening = TrashRetention.choices.first { $0.seconds == seconds }
            } else {
                keep(for: seconds)
            }
        }
    }

    /// The list stays as it was if the server refuses, because it's the server's time that counts.
    private func keep(for seconds: Int) {
        Task {
            do {
                try await drives.setTrashRetention(seconds: seconds, of: connection)
                retention = seconds
                problem = nil
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if connection.settings.mode == .unsafe {
                Text("This drive is in Unsafe mode, so what's deleted now is gone for good. Files deleted before stay listed here, and can be restored in Safe mode.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if isLoading {
                // The list's own size, so nothing moves when the server answers.
                BoundedList(rows: 0, rowHeight: RowHeight.double, visibleRows: 7, reserves: true) {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, minHeight: RowHeight.double)
                }
            } else if entries.isEmpty {
                Text("Nothing deleted.")
                    .foregroundStyle(.secondary)
            } else {
                deletedItems
            }
            if connection.writesControlFolder {
                SettingsSection {
                    let caption = Text("Deleted files stay on the server for at least this long, then go for good, on every device using this drive. Earlier versions of saved files last 7 days at most.")
                    if retention != nil {
                        PickerRow("Keep deleted files for", selection: retentionChoice, caption: caption) {
                            ForEach(TrashRetention.choices) { choice in
                                Text(choice.label).tag(choice.seconds)
                            }
                        }
                    } else {
                        SettingRow(Text("Keep deleted files for"), caption: caption) {
                            Text(isLoading ? LocalizedStringKey("Checking…") : LocalizedStringKey("Couldn't check"))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if let problem {
                Text(problem)
                    .foregroundStyle(.red)
            }
        }
        .task {
            await load()
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.refreshInterval)
                if !Task.isCancelled, let retention, retention <= Self.refreshesUpTo {
                    await load()
                }
            }
        }
        .confirmationDialog(
            "Keep deleted files for \(shortening?.label ?? "")?",
            isPresented: Binding { shortening != nil } set: { if !$0 { shortening = nil } },
            presenting: shortening
        ) { choice in
            Button("Keep for \(choice.label)", role: .destructive) { keep(for: choice.seconds) }
            Button("Cancel", role: .cancel) {}
        } message: { choice in
            Text("Anything deleted more than \(choice.label) ago is removed from the server for good, on every device using this drive. This can't be undone.")
        }
        .confirmationDialog(
            "Delete \(chosenShown.count) items for good?", isPresented: $isConfirmingPurge
        ) {
            Button("Delete Now", role: .destructive) { purgeChosen() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They're removed from the server now, for every device using this drive. This can't be undone.")
        }
        // A choice the filter or search hides is let go, so it can't be deleted unseen.
        .onChange(of: filtersFiles) { keepOnlyShownChoices() }
        .onChange(of: search) { keepOnlyShownChoices() }
    }

    private func keepOnlyShownChoices() {
        chosen.formIntersection(visibleEntries.map(\.id))
    }

    @ViewBuilder
    private var deletedItems: some View {
        if fileCount > 0 {
            Card {
                IconRow("line.3.horizontal.decrease", String(localized: "Filter files"), subtitle: filterNote) {
                    RowSwitch(label: "Filter files", isOn: $filtersFiles)
                }
            }
        }
        if entries.count > Self.searchThreshold {
            TextField("Search", text: $search)
                .textFieldStyle(.roundedBorder)
        }
        if canPurge {
            Toggle("Select all", isOn: allShownChosen)
                .toggleStyle(.checkbox)
                .disabled(visibleEntries.isEmpty || isPurging)
        }
        BoundedList(rows: visibleEntries.count, rowHeight: RowHeight.double, visibleRows: 7) {
            if visibleEntries.isEmpty {
                Text(filtersFiles ? "No deleted folders." : "Nothing matches.")
                    .foregroundStyle(.secondary)
                    .frame(height: RowHeight.double)
            }
            ForEach(visibleEntries) { entry in
                ListRow(height: RowHeight.double) {
                    HStack(spacing: 8) {
                        if canPurge {
                            Toggle(isOn: isChosen(entry)) { Text(verbatim: entryTitle(entry)) }
                                .toggleStyle(.checkbox)
                                .labelsHidden()
                                .disabled(isPurging)
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entryTitle(entry))
                            Text(Date(timeIntervalSince1970: TimeInterval(entry.deletedAt)).formatted())
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } controls: {
                    if !entry.isDamaged, connection.writesControlFolder {
                        Button("Restore") { restore(entry) }
                            .buttonStyle(.pill)
                            .disabled(isPurging)
                    }
                }
            }
        }
        if canPurge {
            SettingsSection {
                SettingRow(Text(String(localized: "\(chosenShown.count) selected"))) {
                    Button("Delete Now…") { isConfirmingPurge = true }
                        .buttonStyle(.destructivePill)
                        .disabled(chosenShown.isEmpty || isPurging)
                }
            }
        }
        if let purgeNote {
            Text(purgeNote)
                .foregroundStyle(.secondary)
        }
    }

    /// Only where Restore is offered: a drive that keeps the control folder, so not read-only and
    /// not Unsafe. The engine refuses it anywhere else too.
    private var canPurge: Bool {
        connection.writesControlFolder
    }

    /// What's chosen among what's shown. A choice hidden by the filter or search is never deleted.
    private var chosenShown: [RemoteEngine.TrashEntry] {
        visibleEntries.filter { chosen.contains($0.id) }
    }

    private var allShownChosen: Binding<Bool> {
        Binding {
            !visibleEntries.isEmpty && visibleEntries.allSatisfy { chosen.contains($0.id) }
        } set: { isOn in
            let shown = visibleEntries.map(\.id)
            if isOn {
                chosen.formUnion(shown)
            } else {
                chosen.subtract(shown)
            }
        }
    }

    private func isChosen(_ entry: RemoteEngine.TrashEntry) -> Binding<Bool> {
        Binding {
            chosen.contains(entry.id)
        } set: { isOn in
            if isOn {
                chosen.insert(entry.id)
            } else {
                chosen.remove(entry.id)
            }
        }
    }

    /// Deletes what's chosen and shown, after the person has confirmed. What fails stays chosen
    /// and listed, with its reason.
    private func purgeChosen() {
        let doomed = chosenShown
        guard !doomed.isEmpty else { return }
        isPurging = true
        purgeNote = nil
        Task {
            var deleted = 0
            do {
                deleted = try await drives.purge(doomed, in: connection)
                problem = nil
            } catch {
                problem = error.localizedDescription
            }
            await load()
            if deleted > 0 {
                purgeNote = String(localized: "\(deleted) items deleted")
            }
            isPurging = false
        }
    }

    private func entryTitle(_ entry: RemoteEngine.TrashEntry) -> String {
        if entry.isDamaged { return String(localized: "Damaged entry") }
        let path = FlattenedPackage.shownName(entry.originalPath)
        return entry.isVersion ? String(localized: "Earlier version of \(path)") : path
    }

    private func load() async {
        do {
            entries = try await drives.trashEntries(of: connection)
                .sorted { $0.deletedAt > $1.deletedAt }
            // What's left the trash, here or on another device, is no longer chosen.
            chosen.formIntersection(entries.map(\.id))
            retention = await drives.trashRetentionSeconds(of: connection)
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
        isLoading = false
    }

    private func restore(_ entry: RemoteEngine.TrashEntry) {
        Task {
            do {
                try await drives.restore(entry, in: connection)
                await load()
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}
