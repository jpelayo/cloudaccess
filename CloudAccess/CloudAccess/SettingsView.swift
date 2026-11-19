// Apache 2 license - developer@infinitecontext.com

import CloudCore
import CloudDesign
import RemoteEngine
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(Drives.self) private var drives
    @State private var isConfirmingForgetAll = false
    @State private var diagnostics: TextFile?
    @State private var isExporting = false
    @State private var isChoosingImport = false
    @State private var importing: DrivesFileToImport?
    @State private var drivesFileProblem: String?
    @State private var language = AppLanguage.chosen()
    /// Apple reads the language at launch, so a new choice waits for a restart.
    @State private var languageChanged = false

    private var languageChoice: Binding<AppLanguage> {
        Binding {
            language
        } set: { chosen in
            AppLanguage.choose(chosen)
            language = chosen
            languageChanged = true
        }
    }

    private var launchAtLogin: Binding<Bool> {
        Binding {
            drives.loginStatus != .off
        } set: { isOn in
            LoginAgent.set(isOn)
            drives.noteLoginChanged()
        }
    }

    private var version: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    /// The header stays put, and the rest scrolls inside the window when it doesn't fit. The window
    /// never changes size, whatever appears in it.
    var body: some View {
        SheetPage(width: Pane.windowWidth, height: Pane.windowHeight, headerTop: 8) {
            // The window's close button sits to the left of this line.
            PanelHeader(title: "CloudAccess", detail: version) {
                OverallPill { connection in
                    AppWindows.showDrive(connection, .information, drives: drives)
                }
            }
            .padding(.leading, 26)
        } content: {
            settings
        }
        .ignoresSafeArea(.container, edges: .top)
        .confirmationDialog("Forget all kept files?", isPresented: $isConfirmingForgetAll) {
            Button("Forget All", role: .destructive) { drives.forgetAllPreserved() }
        } message: {
            Text("The files stay on this Mac, but CloudAccess stops showing where they are.")
        }
        .savesText($diagnostics, named: "CloudAccess Diagnostics.txt")
        .sheet(isPresented: $isExporting) {
            ExportDrivesView(drives: drives.exportable)
                .presentationBackground(.regularMaterial)
                .presentationSizing(.fitted)
        }
        .fileImporter(isPresented: $isChoosingImport, allowedContentTypes: [.drivesFile]) { result in
            do {
                importing = DrivesFileToImport(data: try DrivesFileAccess.read(result.get()))
            } catch {
                drivesFileProblem = error.localizedDescription
            }
        }
        .sheet(item: $importing) { file in
            ImportDrivesView(file: file)
                .presentationBackground(.regularMaterial)
                .presentationSizing(.fitted)
        }
    }

    @ViewBuilder
    private var settings: some View {
            if drives.needsEnabling {
                PermissionRow("Turn on CloudAccess in System Settings.") {
                    drives.openExtensionSettings()
                }
            }
            if drives.loginStatus == .needsApproval {
                PermissionRow("Allow CloudAccess in Login Items.") {
                    LoginAgent.openLoginItems()
                }
            }
            ForEach(drives.deviceProblems, id: \.title) { problem in
                if let title = problem.title {
                    if problem.opensTailscale {
                        PermissionRow(title, button: "Open Tailscale", action: drives.hasTailscale ? { drives.openTailscale() } : nil)
                    } else {
                        switch problem.finding?.action {
                        case .openLocalNetworkSettings?:
                            PermissionRow(title, action: { drives.openLocalNetworkSettings() })
                        default:
                            PermissionRow(title, action: nil)
                        }
                    }
                }
            }
            if let storeProblem = drives.storeProblem {
                Text(storeProblem)
                    .foregroundStyle(.red)
            }
            VStack(alignment: .leading, spacing: Design.labelGap) {
                HStack {
                    SectionLabel("Drives")
                    Spacer()
                    Button("Add Drive…", systemImage: "plus") {
                        AppWindows.showAddDrive(drives: drives)
                    }
                    .buttonStyle(.pill)
                    .disabled(drives.isUninstalling)
                }
                BoundedList(rows: drives.connections.count, rowHeight: RowHeight.double, visibleRows: 4) {
                    if drives.connections.isEmpty && drives.storeProblem == nil {
                        Text("No drives yet.")
                            .foregroundStyle(.secondary)
                            .frame(height: RowHeight.double)
                    }
                    ForEach(drives.connections) { connection in
                        DriveRow(connection: connection) { kind in
                            AppWindows.showDrive(connection, kind, drives: drives)
                        }
                    }
                }
            }
            if !drives.preservedFiles.isEmpty {
                VStack(alignment: .leading, spacing: Design.labelGap) {
                    HStack {
                        SectionLabel("Files kept from removed drives")
                        Spacer()
                        Button("Forget All…") { isConfirmingForgetAll = true }
                            .buttonStyle(.pill)
                    }
                    BoundedList(rows: drives.preservedFiles.count, rowHeight: RowHeight.double, visibleRows: 3) {
                        ForEach(drives.preservedFiles) { files in
                            ListRow(height: RowHeight.double) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(files.driveName)
                                    Text(files.date.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } controls: {
                                Button("Show in Finder", systemImage: "magnifyingglass") {
                                    drives.revealPreserved(files)
                                }
                                .buttonStyle(.icon)
                                .help("Show in Finder")
                                Button("Forget", systemImage: "xmark") { drives.forgetPreserved(files) }
                                    .buttonStyle(.icon)
                                    .help("Forget")
                            }
                        }
                    }
                }
            }
            if !drives.unknownDomains.isEmpty {
                Text("Finder has \(drives.unknownDomains.count) CloudAccess locations with no drive behind them, likely left by an earlier install. They do no harm, and CloudAccess leaves them as they are.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            CardSection("General") {
                IconRow("power", "Launch at login", subtitle: "Keeps your drives up to date") {
                    RowSwitch(label: "Launch at login", isOn: launchAtLogin)
                }
                IconRow("stethoscope", "Diagnostics", subtitle: "A report with secrets removed") {
                    Button("Export…") {
                        diagnostics = TextFile(text: drives.diagnosticsText())
                    }
                    .buttonStyle(.pill)
                }
                IconRow("globe", "Language", subtitle: "System follows your Mac's language") {
                    Picker("Language", selection: languageChoice) {
                        ForEach(AppLanguage.allCases, id: \.self) { choice in
                            Text(verbatim: choice.title).tag(choice)
                        }
                    }
                    .labelsHidden()
                    .inColumn(Pane.valueColumn)
                }
                if languageChanged {
                    if LoginAgent.canRestart {
                        IconRow("arrow.clockwise", "The new language shows after a restart") {
                            Button("Restart Now") { LoginAgent.restart() }
                                .buttonStyle(.pill)
                        }
                    } else {
                        IconRow(
                            "arrow.clockwise", "The new language shows after a restart",
                            subtitle: "Quit, then open CloudAccess again"
                        ) {
                            Button("Quit") { LoginAgent.quit() }
                                .buttonStyle(.pill)
                        }
                    }
                }
                IconRow("square.and.arrow.up.on.square", "Export drives", subtitle: "Drives and passwords, in one encrypted file") {
                    Button("Export…") {
                        Task {
                            drivesFileProblem = nil
                            if await DrivesFileAccess.confirmOwner() {
                                isExporting = true
                            }
                        }
                    }
                    .buttonStyle(.pill)
                    .disabled(drives.exportable.isEmpty)
                }
                IconRow("square.and.arrow.down.on.square", "Import drives", subtitle: "From a drives file, one drive at a time") {
                    Button("Import…") {
                        drivesFileProblem = nil
                        isChoosingImport = true
                    }
                    .buttonStyle(.pill)
                    .disabled(drives.isUninstalling)
                }
                if let drivesFileProblem {
                    FieldNote(drivesFileProblem)
                }
                IconRow("iphone", "CloudWanderer for iPhone", subtitle: "Your drives on your phone") {
                    Button("Learn More…") {
                        AppWindows.showCloudWanderer()
                    }
                    .buttonStyle(.pill)
                }
                IconRow("info.circle", "About CloudAccess") {
                    Button("Show…") {
                        About.show()
                    }
                    .buttonStyle(.pill)
                }
            }
    }
}

/// A drive's window. The drive list leaves a drive out as soon as its removal starts, so the window
/// keeps the drive it opened with, or it would go blank while the removal shows its progress.
struct DriveWindowView: View {
    @Environment(Drives.self) private var drives

    let request: DriveRequest

    @State private var openedWith: Connection?

    var body: some View {
        Group {
            if let connection = drives.connections.first(where: { $0.id == request.driveID }) ?? openedWith {
                switch request.sheet {
                case .settings:
                    DriveDetailView(connection: connection)
                case .deletedFiles:
                    DriveDetailView(connection: connection, startingPage: .deleted)
                case .information:
                    DriveDetailView(connection: connection, startingPage: .information)
                case .code:
                    ConnectionCodeView(connection: connection, signsInWithKey: drives.signsInWithKey(connection))
                }
            }
        }
        .onAppear {
            openedWith = drives.connections.first { $0.id == request.driveID }
        }
    }
}

/// Something macOS is still waiting for. It comes first, because nothing works without it.
private struct PermissionRow: View {
    let text: Text
    let button: Text
    let action: (() -> Void)?

    /// The text and the button are looked up in the app's strings.
    init(_ text: LocalizedStringKey, button: LocalizedStringKey = "Open System Settings", action: (() -> Void)?) {
        self.text = Text(text)
        self.button = Text(button)
        self.action = action
    }

    @_disfavoredOverload
    init(_ text: some StringProtocol, button: LocalizedStringKey = "Open System Settings", action: (() -> Void)?) {
        self.text = Text(verbatim: String(text))
        self.button = Text(button)
        self.action = action
    }

    var body: some View {
        Card {
            HStack {
                Label {
                    text
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .foregroundStyle(.orange)
                Spacer()
                if let action {
                    Button(action: action) { button }
                        .buttonStyle(.pill)
                }
            }
        }
    }
}

/// A drive in the list, with the same buttons as its row in the panel.
private struct DriveRow: View {
    @Environment(Drives.self) private var drives

    let connection: Connection
    let open: (DriveRequest.Sheet) -> Void

    private var color: Color {
        switch drives.light(of: connection) {
        case .green: .green
        case .yellow: .yellow
        case .red: .red
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)
                .accessibilityLabel(drives.light(of: connection).description)
            // One line each, so a long status in Spanish can't push out of its row.
            VStack(alignment: .leading, spacing: 0) {
                Text(connection.displayName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let status = drives.statusLabel(of: connection) {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(status)
                }
            }
            Spacer(minLength: 8)
            DriveActivitySign(connection: connection, turns: false) {
                open(.information)
            }
            DriveButtons(connection: connection) {
                open(.code)
            }
            Button("Details…") {
                open(.settings)
            }
            .buttonStyle(.pill)
        }
        .frame(height: RowHeight.double)
    }
}

/// Offered once, straight after a new encrypted drive is made, because a lost password can't be
/// recovered. It's under Advanced for later.
struct RecoveryKitOffer: View {
    @Environment(Drives.self) private var drives
    @Environment(\.dismiss) private var dismiss
    @Environment(\.closeWindow) private var closeWindow

    let connection: Connection

    /// It's a window of its own, or a sheet.
    private func close() {
        if let closeWindow { closeWindow() } else { dismiss() }
    }

    @State private var kit: TextFile?
    @State private var isSaved = false
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Design.sectionGap) {
            Text("Save a recovery kit")
                .font(.system(size: 15, weight: .bold))
            Text("It holds this drive's password and everything else needed to reach your files without this app. A lost password can't be recovered, so keep the kit somewhere safe, away from the drive.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let problem {
                FieldNote(problem)
            }
            if isSaved {
                Label("Recovery kit saved", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Button("Done") { close() }
                    .buttonStyle(.bar(.blue))
            } else {
                Button("Save Recovery Kit…") {
                    Task {
                        do {
                            kit = TextFile(text: try await drives.recoveryKit(for: connection))
                        } catch {
                            problem = error.localizedDescription
                        }
                    }
                }
                .buttonStyle(.bar(.blue))
                Button("Not Now") { close() }
                    .buttonStyle(.pill)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(20)
        .frame(width: 400)
        .savesText($kit, named: "\(connection.displayName) Recovery Kit.txt") {
            isSaved = true
            problem = nil
        }
    }
}

struct AddDriveView: View {
    @Environment(Drives.self) private var drives
    @Environment(\.dismiss) private var dismiss
    @Environment(\.closeWindow) private var closeWindow

    /// Told about a new encrypted drive just before this closes, so its recovery kit is offered.
    let addedEncryptedDrive: (Connection) -> Void

    @State private var form = ConnectionForm()
    @State private var password = ""
    @State private var privateKey: String?
    @State private var privateKeyName: String?
    @State private var keyPassphrase = ""
    @State private var isChoosingKey = false
    @State private var isEncrypted = false
    @State private var vaultPassword = ""
    @State private var showsVaultPassword = false
    /// An SFTP server's identity, once a person has trusted it.
    @State private var hostKey: RemoteEngine.HostKey?
    /// A new server's identity, waiting to be trusted.
    @State private var askingTrust: PendingTrust?
    @State private var allowsInsecure = false
    @State private var isConnecting = false
    @State private var problem: FormNote?
    @State private var browsing: FolderBrowsing?
    /// What the folder holds, and the server, account and folder it was read for, so a reading
    /// never outlives the fields it was made from.
    @State private var folderCheck: (key: String, contents: FolderContents)?
    /// The other reading of an SFTP folder that isn't there, when that one is.
    @State private var otherFolder: String?

    /// The fields as they'll be used, so a pasted address counts before it's been split up.
    private var tidied: ConnectionForm {
        var copy = form
        copy.tidyHost()
        return copy
    }

    private var isSFTP: Bool {
        tidied.kind == .sftp
    }

    private var isInsecure: Bool {
        tidied.kind == .http
    }

    private var canBrowse: Bool {
        tidied.browsingConnection() != nil && (!isInsecure || allowsInsecure) && !isConnecting
    }

    /// The same rule as the iPhone's add form.
    private var canConnect: Bool {
        form.canConnect(isEncrypted: isEncrypted, hasVaultPassword: !vaultPassword.isEmpty, allowsInsecure: allowsInsecure)
    }

    private var signIn: Credentials {
        Credentials(
            password: password.isEmpty ? nil : password,
            privateKeyPEM: privateKey,
            privateKeyPassphrase: keyPassphrase.isEmpty ? nil : keyPassphrase,
            vaultPassword: isEncrypted ? vaultPassword : nil)
    }

    /// Which server these fields reach. A different one can't inherit a trusted identity.
    private var serverIdentity: String {
        "\(form.kind.rawValue) \(form.host) \(form.port)"
    }

    /// The server, account and folder a reading of the folder belongs to.
    private var folderKey: String {
        "\(serverIdentity) \(form.username) \(form.path)"
    }

    private var folderContents: FolderContents? {
        folderCheck.flatMap { $0.key == folderKey ? $0.contents : nil }
    }

    /// The same rule as the iPhone's add form.
    private var encryptionChoice: EncryptionChoice {
        EncryptionChoice.for(folderContents, device: .mac)
    }

    /// The folder already has plain files, so encryption can't be used here at all.
    private var isEncryptionUnusable: Bool {
        encryptionChoice.lockedValue == false
    }

    /// What a reading of the folder depends on, so it's read again when any of it changes:
    /// the folder, the server being trusted, or a sign-in being typed.
    private var folderCheckTrigger: String {
        "\(folderKey) \(hostKey?.key ?? "") \(password.isEmpty) \(privateKey != nil)"
    }

    /// A fixed size: the cards that appear after Connect, such as the server's identity, scroll
    /// into view instead of growing the sheet.
    var body: some View {
        SheetPage(height: Pane.formHeight) {
            CardSection("Server") {
                FieldRow(label: "Name", text: $form.name)
                SettingRow("Protocol") {
                    Picker("Protocol", selection: $form.kind) {
                        ForEach(ConnectionForm.Kind.allCases, id: \.self) { kind in
                            Text(kind.title)
                        }
                    }
                    // Ends where the fields above and below it end.
                    .inColumn(Pane.fieldColumn)
                }
                FieldRow(label: "Host", text: $form.host, prompt: "example.com")
                FieldRow(label: "Port", text: $form.port, prompt: form.kind.defaultPort)
                note(for: [.address, .port])
                if isInsecure {
                    SettingRow("Send my password unencrypted over http") {
                        RowSwitch(label: "Send my password unencrypted over http", isOn: $allowsInsecure)
                    }
                }
                FieldRow(label: "User", text: $form.username)
                FieldRow(label: "Password", text: $password, isSecure: true)
                if isSFTP {
                    SettingRow("Private key") {
                        Button(privateKeyName ?? String(localized: "Choose…")) { isChoosingKey = true }
                            .buttonStyle(.pill)
                    }
                    if privateKey != nil {
                        FieldRow(label: "Key passphrase", text: $keyPassphrase, prompt: "If it has one", isSecure: true)
                    }
                }
                note(for: [.signIn])
                FieldRow(label: "Folder", text: $form.path, prompt: isSFTP ? LocalizedStringKey("Home folder") : LocalizedStringKey("Top folder"))
                // On SFTP, Documents and /Documents are two places, so it says which this is.
                if let folderProblem = tidied.folderProblem {
                    FieldNote(folderProblem)
                } else if let place = tidied.shownPlace {
                    Text(place)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                SettingRow("Choose it on the server") {
                    Button("Browse…") { browse() }
                        .buttonStyle(.pill)
                        .disabled(!canBrowse)
                }
                note(for: [.folder])
            }
            CardSection("Encryption") {
                // A folder that already has plain files can't be encrypted, so the whole section
                // is greyed out, with the reason and the way round it under it.
                VStack(alignment: .leading, spacing: Design.labelGap) {
                    SettingRow("Enable encryption") {
                        RowSwitch(label: "Enable encryption", isOn: $isEncrypted)
                            .disabled(encryptionChoice.lockedValue != nil)
                    }
                    Text(isEncrypted
                        ? "This can't be changed later. A lost password can't be recovered, and neither can the files. Save a recovery kit from the drive's details afterwards."
                        : "This can't be changed later.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .disabled(isEncryptionUnusable)
                .opacity(isEncryptionUnusable ? 0.4 : 1)
                if isEncryptionUnusable {
                    if let reason = encryptionChoice.reason {
                        FieldNote(reason)
                    }
                    // Plain files and an encrypted drive can't share a folder, so encrypting
                    // means a new one, made inside this one.
                    SettingRow("Make the folder \(tidied.ownFolderName) here") {
                        Button("Create") { makeOwnFolder() }
                            .buttonStyle(.pill)
                            .disabled(isConnecting || tidied.ownFolderName.isEmpty)
                    }
                }
                if isEncrypted {
                    FieldRow(label: "Encryption password", text: $vaultPassword, isSecure: !showsVaultPassword)
                    SettingRow("A long random password") {
                        Button("Generate") {
                            vaultPassword = Passphrase.generate()
                            showsVaultPassword = true
                        }
                        .buttonStyle(.pill)
                    }
                }
                if !isEncryptionUnusable, let reason = encryptionChoice.reason {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            note(for: [.server, .thisDevice])
            if let otherFolder {
                SettingRow(ServerFolder.shown(otherFolder)) {
                    Button("Use This Folder") {
                        form.path = otherFolder
                        self.otherFolder = nil
                        problem = nil
                    }
                    .buttonStyle(.pill)
                }
            }
        } footer: {
            footer
        }
        .fileImporter(isPresented: $isChoosingKey, allowedContentTypes: [.item], onCompletion: loadKey)
        .fileDialogBrowserOptions(.includeHiddenFiles)
        .onChange(of: serverIdentity) {
            hostKey = nil
            otherFolder = nil
        }
        .onChange(of: form.path) {
            otherFolder = nil
        }
        .onChange(of: encryptionChoice) {
            if let only = encryptionChoice.lockedValue {
                isEncrypted = only
            }
        }
        // The folder is read once typing stops, and again once the server is trusted or a sign-in
        // is typed, so the switch shows what's possible before Connect.
        .task(id: folderCheckTrigger) {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            await checkFolder()
        }
        .sheet(item: $browsing) { session in
            ServerFolderPicker(session: session) { folder in
                form.path = session.start.folderField(for: folder)
                Task { await checkFolder() }
            }
            .presentationBackground(.regularMaterial)
            .presentationSizing(.fitted)
        }
        .trustingServer($askingTrust) { hostKey = $0 }
    }

    /// Connect, kept at the bottom of the window whatever's above it. Cancel is the window's own
    /// close button too, and Escape.
    private var footer: some View {
        VStack(spacing: 8) {
            Button("Connect") { connect() }
                .buttonStyle(.bar(.blue))
                .keyboardShortcut(.defaultAction)
                .disabled(!canConnect || isConnecting)
            Button("Cancel") { close() }
                .buttonStyle(.pill)
                .keyboardShortcut(.cancelAction)
                .frame(maxWidth: .infinity)
        }
    }

    /// It's a window of its own, or a sheet.
    private func close() {
        if let closeWindow { closeWindow() } else { dismiss() }
    }

    private func loadKey(_ result: Result<URL, Error>) {
        do {
            let key = try PrivateKeyFile(result)
            privateKey = key.text
            privateKeyName = key.name
            problem = nil
        } catch {
            let reason = error.localizedDescription
            problem = FormNote(String(localized: "That key can't be read: \(reason)"), field: .signIn)
        }
    }

    /// The engine's path for a refusal is `/`, the drive's own folder, which reads as the server's.
    /// A server that can't be reached is checked first, so the line says which part failed.
    private func failureNote(for error: Error, connection: Connection) async -> FormNote {
        if case RemoteError.forbidden = error {
            return FormNote(
                String(localized: "The server refused to open this folder"), field: .folder,
                details: String(localized: "The server refused to open this folder. Check that this user can read it. On a Mac server, Documents, Desktop and Downloads also need \"Allow full disk access for remote users\", under System Settings, General, Sharing, Remote Login."))
        }
        return await ConnectionChecks.note(for: error, connection: connection, device: .mac)
    }

    /// The problem, if it's about one of these fields, as one calm line under them.
    @ViewBuilder
    private func note(for fields: [ConnectionFinding.Field]) -> some View {
        if let problem, fields.contains(problem.field) {
            FieldNote(problem)
        }
    }

    /// Connects to the server alone, with nothing written, to look through its folders.
    private func browse() {
        form = tidied
        let start = form.browseStart
        guard var connection = start.browsingConnection(hostKey: hostKey?.key) else {
            problem = FormNote(String(localized: "Check the server's details."), field: .address)
            return
        }
        connection.allowsInsecure = allowsInsecure
        isConnecting = true
        problem = nil
        Task {
            defer { isConnecting = false }
            do {
                #if DEBUG
                guard connection.isTestDrive else { throw Drives.DriveError.notATestFolder }
                #endif
                // A new server is trusted once, and Browse carries on after.
                if case .sftp(let host, let port) = connection.endpoint, hostKey == nil {
                    let offered = try await ServerTrust.offered(host: host, port: port, among: drives.connections)
                    guard !offered.mustAsk else {
                        askingTrust = PendingTrust(host: host, key: offered.key, resume: browse)
                        return
                    }
                    hostKey = offered.key
                    connection.hostKey = offered.key.key
                }
                let engine = try await RemoteEngine(connection: connection, credentials: signIn)
                browsing = FolderBrowsing(start: start, engine: engine, typed: form.typedFolder(inside: start))
            } catch {
                problem = FormNote(String(localized: "Couldn't connect. Checking why…"))
                problem = await failureNote(for: error, connection: connection)
            }
        }
    }

    /// Reads what the folder holds, so the encryption switch shows only what's possible there. It
    /// needs a trusted server and a sign-in, and writes nothing. A failure leaves the switch free,
    /// and Connect says what's wrong.
    private func checkFolder() async {
        let key = folderKey
        guard folderCheck?.key != key, !password.isEmpty || privateKey != nil,
              !isInsecure || allowsInsecure,
              var probe = tidied.browsingConnection(hostKey: hostKey?.key)
        else { return }
        // An SFTP server is only signed in to once its identity is trusted.
        if case .sftp = probe.endpoint, probe.hostKey == nil { return }
        #if DEBUG
        guard probe.isTestDrive else { return }
        #endif
        probe.allowsInsecure = allowsInsecure
        var credentials = signIn
        credentials.vaultPassword = nil
        guard let contents = try? await RemoteEngine.folderContents(of: probe, credentials: credentials),
              key == folderKey
        else { return }
        folderCheck = (key, contents)
    }

    /// Makes a folder named after the drive inside the one chosen, and points the form at it, so
    /// an encrypted drive can start there. Nothing is connected until Connect.
    private func makeOwnFolder() {
        form = tidied
        guard var connection = form.browsingConnection(hostKey: hostKey?.key),
              let folder = RemotePath.root.appending(form.ownFolderName)
        else {
            problem = FormNote(String(localized: "That name can't be used for a folder."), field: .folder)
            return
        }
        connection.allowsInsecure = allowsInsecure
        isConnecting = true
        problem = nil
        Task {
            defer { isConnecting = false }
            do {
                #if DEBUG
                guard connection.isTestDrive else { throw Drives.DriveError.notATestFolder }
                #endif
                var credentials = signIn
                credentials.vaultPassword = nil
                let engine = try await RemoteEngine(connection: connection, credentials: credentials)
                try await engine.createDirectory(folder)
                form.path = form.folderField(for: folder)
                folderCheck = (folderKey, .empty)
                isEncrypted = true
            } catch {
                problem = FormNote(String(localized: "Couldn't connect. Checking why…"))
                let found = await failureNote(for: error, connection: connection)
                problem = FormNote(String(localized: "That folder couldn't be made: \(found.text)"), field: .folder, details: found.details, steps: found.steps)
            }
        }
    }

    private func connect() {
        form = tidied
        guard var connection = form.newConnection(isEncrypted: isEncrypted, hostKey: hostKey?.key) else {
            problem = FormNote(String(localized: "Check the name and the server's details."), field: .address)
            return
        }
        connection.allowsInsecure = allowsInsecure
        isConnecting = true
        problem = nil
        Task {
            defer { isConnecting = false }
            do {
                // A new server is trusted once, and Connect carries on after.
                if case .sftp(let host, let port) = connection.endpoint, hostKey == nil {
                    let offered = try await ServerTrust.offered(host: host, port: port, among: drives.connections)
                    guard !offered.mustAsk else {
                        askingTrust = PendingTrust(host: host, key: offered.key, resume: connect)
                        return
                    }
                    hostKey = offered.key
                    connection.hostKey = offered.key.key
                }
                let saved = try await drives.add(connection, credentials: signIn)
                if saved.isEncrypted {
                    addedEncryptedDrive(saved)
                }
                close()
            } catch RemoteError.vault(.encrypted) {
                // The folder already holds an encrypted drive, so only its password is needed.
                // The switch turns on, with the reason under it.
                folderCheck = (folderKey, .encryptedDrive)
            } catch RemoteError.vault(.missing) {
                // Plain files are there: the switch turns off, with a row to make a new folder.
                folderCheck = (folderKey, .plainFiles)
            } catch RemoteError.notFound(let path) where path.isRoot {
                // On SFTP, Documents and /Documents are two places: the other may be the one meant.
                if let other = await RemoteEngine.otherReading(of: connection, credentials: signIn) {
                    otherFolder = other
                    problem = FormNote(ServerFolder.missingFolder(connection.rootPath, other: other), field: .folder)
                } else {
                    problem = FormNote(String(localized: "Couldn't connect: that folder isn't on the server."), field: .folder)
                }
            } catch {
                problem = FormNote(String(localized: "Couldn't connect. Checking why…"))
                problem = await failureNote(for: error, connection: connection)
            }
        }
    }
}
