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

/// The heights rows come in. A list works out its own height from these, so it always shows
/// whole rows and never cuts one in half.
enum RowHeight {
    static let single: CGFloat = 30
    static let double: CGFloat = 42
}

/// The only thing in a window that scrolls. A list that can grow lives in one of these, and the
/// window around it never scrolls: a drive can have a thousand folders. A short list shrinks
/// to fit, and a long one shows `visibleRows` whole rows.
struct BoundedList<Content: View>: View {
    let rows: Int
    let rowHeight: CGFloat
    let visibleRows: Int
    @ViewBuilder let content: Content

    private static var padding: CGFloat { 6 }

    private var height: CGFloat {
        CGFloat(min(max(rows, 1), visibleRows)) * rowHeight + Self.padding * 2
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                content
            }
            .padding(.horizontal, 10)
            .padding(.vertical, Self.padding)
        }
        .frame(height: height)
        .cardSurface()
    }
}

/// A row with its label on the left and its controls lined up on the right. `LabeledContent`
/// only does this inside a `Form`, and no window here uses one, because a `Form` scrolls.
struct ListRow<Label: View, Controls: View>: View {
    let height: CGFloat
    @ViewBuilder let label: Label
    @ViewBuilder let controls: Controls

    var body: some View {
        HStack(spacing: 8) {
            label
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            controls
        }
        .frame(height: height)
    }
}

/// One setting on one line, so a page fits without scrolling.
struct SettingRow<Control: View>: View {
    let label: Text
    @ViewBuilder let control: Control

    /// The label is looked up in the app's strings.
    init(_ label: LocalizedStringKey, @ViewBuilder control: () -> Control) {
        self.init(Text(label), control: control)
    }

    /// Words already in the language shown, or a name, appear as they are.
    @_disfavoredOverload
    init(_ label: some StringProtocol, @ViewBuilder control: () -> Control) {
        self.init(Text(verbatim: String(label)), control: control)
    }

    init(_ label: Text, @ViewBuilder control: () -> Control) {
        self.label = label
        self.control = control()
    }

    var body: some View {
        ListRow(height: 26) {
            label
        } controls: {
            control
                .labelsHidden()
                .fixedSize()
        }
    }
}

/// A switch that lines up with the other controls.
struct RowSwitch: View {
    let label: Text
    @Binding var isOn: Bool

    /// The label is looked up in the app's strings. It's hidden, and read out by VoiceOver.
    init(label: LocalizedStringKey, isOn: Binding<Bool>) {
        self.label = Text(label)
        _isOn = isOn
    }

    @_disfavoredOverload
    init(label: some StringProtocol, isOn: Binding<Bool>) {
        self.label = Text(verbatim: String(label))
        _isOn = isOn
    }

    var body: some View {
        Toggle(isOn: $isOn) { label }
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
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
    @State private var problem: String?
    @State private var message: String?
    @State private var hasUnsavedEdits = false
    @State private var saveRequests = 0
    /// What the server's `.cloudmount` folder holds, looked up when the drive stops using it.
    @State private var controlFolder: RemoteEngine.ControlFolder?
    @State private var isOfferingCleanUp = false

    init(connection: Connection, startingPage: Page = .general) {
        self.connection = connection
        _page = State(initialValue: startingPage)
    }

    /// The Information page is for reading, so it can be made as big as it takes. The others are
    /// laid out to fit their controls.
    private var fillsWindow: Bool {
        page == .information
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
    private func lookAtControlFolder(offering: Bool) async {
        guard case .sftp = current.endpoint, !current.settings.mode.usesControlFolder,
              !current.serverIsReadOnly else {
            controlFolder = nil
            return
        }
        controlFolder = try? await drives.controlFolder(of: current)
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

    var body: some View {
        VStack(alignment: .leading, spacing: Design.sectionGap) {
            if drives.status(of: current) == .offline {
                Label(drives.offlineMessage(of: current), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                if current.usesTailnet {
                    Text(Tailnet.hint)
                        .foregroundStyle(.secondary)
                }
            }
            Picker("Page", selection: $page) {
                ForEach(Page.allCases, id: \.self) { page in
                    Text(page.title)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            // Each page is rebuilt when it's shown, so leaving this one would drop the edit.
            .disabled(hasUnsavedEdits)

            switch page {
            case .general:
                general
            case .advanced:
                advanced
            case .deleted:
                TrashView(connection: current)
            case .information:
                DriveInformationView(connection: current)
            }

            if let message {
                Text(message)
                    .foregroundStyle(.secondary)
            }
            if let problem {
                Text(problem)
                    .foregroundStyle(.red)
            }
            HStack {
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
        .padding(16)
        .frame(
            minWidth: 480, idealWidth: fillsWindow ? 640 : 480, maxWidth: fillsWindow ? .infinity : 480,
            minHeight: fillsWindow ? 460 : nil, idealHeight: fillsWindow ? 640 : nil,
            maxHeight: fillsWindow ? .infinity : nil)
        .fixedSize(horizontal: false, vertical: !fillsWindow)
        .background(ResizableSheet(isResizable: fillsWindow))
        .task {
            await loadFolders()
        }
        .sheet(isPresented: $isShowingCode) {
            ConnectionCodeView(connection: current, signsInWithKey: drives.signsInWithKey(current))
        }
        .savesText($recoveryKit, named: "\(connection.displayName) Recovery Kit.txt")
        .confirmationDialog(
            "Remove \(connection.displayName)?", isPresented: $isConfirmingRemove
        ) {
            Button("Remove", role: .destructive) {
                perform { try await drives.remove(current); dismiss() }
            }
        } message: {
            removeMessage
        }
        .confirmationDialog(
            "Reset \(connection.displayName)?", isPresented: $isConfirmingReset
        ) {
            Button("Reset", role: .destructive) {
                perform { try await drives.reset(current); dismiss() }
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

    /// One whole message either way, so each reads right in every language.
    private var removeMessage: Text {
        let count = drives.unsentCount(of: connection)
        guard count > 0 else { return Text("Everything on the server stays there.") }
        return Text("\(count) files haven't uploaded yet. They'll be kept on this Mac, and Settings shows where. Everything on the server stays there.")
    }

    private var general: some View {
        VStack(alignment: .leading, spacing: Design.sectionGap) {
            CardSection("Connection") {
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
            CardSection("Locally stored file cache") {
                SettingRow("Unused files") {
                    Picker("Unused files", selection: setting(\.removeLocalCopyAfter)) {
                        Text("Clear cache right away").tag(TimeInterval?.some(0))
                        Text("Clear cache after 1 hour").tag(TimeInterval?.some(3600))
                        Text("Clear cache after 1 day").tag(TimeInterval?.some(86_400))
                        Text("Clear cache after 1 week").tag(TimeInterval?.some(604_800))
                        Text("Keep in cache").tag(TimeInterval?.none)
                    }
                }
                SettingRow("Cache size limit") {
                    Picker("Cache size limit", selection: setting(\.sizeLimit)) {
                        Text("1 GB").tag(Int64?.some(1_000_000_000))
                        Text("10 GB").tag(Int64?.some(10_000_000_000))
                        Text("50 GB").tag(Int64?.some(50_000_000_000))
                        Text("No limit").tag(Int64?.none)
                    }
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

    private var keepDownloaded: some View {
        VStack(alignment: .leading, spacing: Design.labelGap) {
            SectionLabel("Keep downloaded")
            if folders.count > Self.filterThreshold {
                TextField("Filter folders", text: $folderFilter)
                    .textFieldStyle(.roundedBorder)
            }
            BoundedList(rows: visibleFolders.count, rowHeight: RowHeight.single, visibleRows: 4) {
                if folders.isEmpty {
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
        }
    }

    private var advanced: some View {
        VStack(alignment: .leading, spacing: Design.sectionGap) {
            keepDownloaded
            CardSection("Behaviour") {
                if current.serverIsReadOnly {
                    SettingRow("Mode") {
                        Text("Read-only, set by the server")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    SettingRow("Mode") {
                        Picker("Mode", selection: mode) {
                            ForEach(DriveMode.available(for: current.endpoint), id: \.self) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                    }
                    Text(current.settings.mode.explanation)
                        .font(.caption)
                        .foregroundStyle(current.settings.mode == .unsafe ? .orange : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                SettingRow("Thumbnails") {
                    Picker("Thumbnails", selection: setting(\.thumbnailLimit)) {
                        Text("Files under 20 MB").tag(Int64?.some(20_000_000))
                        Text("Files under 100 MB").tag(Int64?.some(100_000_000))
                        Text("Off").tag(Int64?.none)
                    }
                }
                SettingRow("Keep free on disk") {
                    Picker("Keep free on disk", selection: setting(\.diskReserve)) {
                        Text("1 GB").tag(Int64?.some(1_000_000_000))
                        Text("5 GB").tag(Int64?.some(5_000_000_000))
                        Text("20 GB").tag(Int64?.some(20_000_000_000))
                        Text("Don't check").tag(Int64?.none)
                    }
                }
                SettingRow("Uploads at once") {
                    Picker("Uploads at once", selection: setting(\.uploadsAtOnce)) {
                        Text("1").tag(1)
                        Text("2").tag(2)
                        Text("4").tag(4)
                        Text("8").tag(8)
                    }
                }
                SettingRow("Check recent folders") {
                    Picker("Check recent folders", selection: setting(\.recentFolderInterval)) {
                        Text("Every minute").tag(TimeInterval(60))
                        Text("Every 5 minutes").tag(TimeInterval(300))
                        Text("Every 15 minutes").tag(TimeInterval(900))
                    }
                }
                SettingRow("Check other folders") {
                    Picker("Check other folders", selection: setting(\.otherFolderInterval)) {
                        Text("Every 30 minutes").tag(TimeInterval(1800))
                        Text("Every hour").tag(TimeInterval(3600))
                        Text("Every 6 hours").tag(TimeInterval(21_600))
                    }
                }
            }
            CardSection("Maintenance") {
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
                        .buttonStyle(.pill)
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
                                .buttonStyle(.pill)
                        }
                    }
                }
                if !current.settings.mode.usesControlFolder, controlFolder?.hasRemovable == true {
                    SettingRow("Hidden .cloudmount folder on the server") {
                        Button("Remove Folder…") { isOfferingCleanUp = true }
                            .buttonStyle(.pill)
                    }
                }
                // Here, not beside Done, where one slip could reach it.
                SettingRow("Take this drive off this Mac") {
                    Button("Remove Drive…", role: .destructive) { isConfirmingRemove = true }
                        .buttonStyle(.pill)
                        .foregroundStyle(.red)
                }
            }
            .disabled(isWorking)
        }
    }

    private func perform(_ work: @escaping @MainActor () async throws -> Void) {
        isWorking = true
        problem = nil
        message = nil
        Task {
            defer { isWorking = false }
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
                ProgressView()
                    .frame(maxWidth: .infinity)
            } else if entries.isEmpty {
                Text("Nothing deleted.")
                    .foregroundStyle(.secondary)
            } else {
                deletedItems
            }
            if connection.writesControlFolder, retention != nil {
                Card {
                    SettingRow("Keep deleted files for") {
                        Picker("Keep deleted files for", selection: retentionChoice) {
                            ForEach(TrashRetention.choices) { choice in
                                Text(choice.label).tag(choice.seconds)
                            }
                        }
                    }
                    Text("Deleted files stay on the server for at least this long, then go for good, on every device using this drive. Earlier versions of saved files last 7 days at most.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
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
        BoundedList(rows: visibleEntries.count, rowHeight: RowHeight.double, visibleRows: 7) {
            if visibleEntries.isEmpty {
                Text(filtersFiles ? "No deleted folders." : "Nothing matches.")
                    .foregroundStyle(.secondary)
                    .frame(height: RowHeight.double)
            }
            ForEach(visibleEntries) { entry in
                ListRow(height: RowHeight.double) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entryTitle(entry))
                        Text(Date(timeIntervalSince1970: TimeInterval(entry.deletedAt)).formatted())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } controls: {
                    if !entry.isDamaged, connection.writesControlFolder {
                        Button("Restore") { restore(entry) }
                            .buttonStyle(.pill)
                    }
                }
            }
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
