// Apache 2 license - developer@infinitecontext.com

import CloudCore
import CloudDesign
import RemoteEngine
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(Drives.self) private var drives
    @State private var isAdding = false
    /// A new encrypted drive, whose recovery kit is offered once the add form has closed. Offered
    /// on top of the form, closing both sheets together left this window's background pale.
    @State private var addedEncryptedDrive: Connection?
    @State private var recoveryKitDrive: Connection?
    @State private var sheet: DriveRequest?
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

    var body: some View {
        VStack(alignment: .leading, spacing: Design.sectionGap) {
            // The window's close button sits to the left of this line.
            PanelHeader(title: "CloudAccess", detail: version) {
                OverallPill { connection in
                    sheet = DriveRequest(driveID: connection.id, sheet: .information)
                }
            }
            .padding(.leading, 26)
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
                    switch problem.finding?.action {
                    case .openTailscale?:
                        PermissionRow(title, button: "Open Tailscale", action: drives.hasTailscale ? { drives.openTailscale() } : nil)
                    case .openLocalNetworkSettings?:
                        PermissionRow(title, action: { drives.openLocalNetworkSettings() })
                    default:
                        PermissionRow(title, action: nil)
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
                        isAdding = true
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
                            sheet = DriveRequest(driveID: connection.id, sheet: kind)
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
                Text("macOS has \(drives.unknownDomains.count) drives that CloudAccess doesn't recognise. They've been left alone.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            CardSection("General") {
                IconRow("power", "Launch at login", subtitle: "Keeps your drives up to date") {
                    RowSwitch(label: "Launch at login", isOn: launchAtLogin)
                }
                IconRow("stethoscope", "Diagnostics", subtitle: "A report with secrets removed") {
                    Button("Export…", systemImage: "square.and.arrow.up") {
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
                    .frame(width: 140)
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
                    Text(drivesFileProblem)
                        .font(.caption)
                        .foregroundStyle(.red)
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
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 16)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .ignoresSafeArea(.container, edges: .top)
        .sheet(isPresented: $isAdding, onDismiss: {
            recoveryKitDrive = addedEncryptedDrive
            addedEncryptedDrive = nil
        }) {
            AddDriveView { addedEncryptedDrive = $0 }
                .presentationBackground(.regularMaterial)
        }
        .sheet(item: $recoveryKitDrive) { connection in
            RecoveryKitOffer(connection: connection)
                .presentationBackground(.regularMaterial)
        }
        .sheet(item: $sheet) { request in
            DriveSheet(request: request)
                .presentationBackground(.regularMaterial)
        }
        .onChange(of: drives.request, initial: true) { _, request in
            guard let request else { return }
            sheet = request
            drives.request = nil
        }
        .onChange(of: drives.wantsAddForm, initial: true) { _, wanted in
            guard wanted else { return }
            isAdding = !drives.isUninstalling
            drives.wantsAddForm = false
        }
        .confirmationDialog("Forget all kept files?", isPresented: $isConfirmingForgetAll) {
            Button("Forget All", role: .destructive) { drives.forgetAllPreserved() }
        } message: {
            Text("The files stay on this Mac, but CloudAccess stops showing where they are.")
        }
        .savesText($diagnostics, named: "CloudAccess Diagnostics.txt")
        .sheet(isPresented: $isExporting) {
            ExportDrivesView(drives: drives.exportable)
                .presentationBackground(.regularMaterial)
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
        }
    }
}

/// A drive's sheet. The drive list leaves a drive out as soon as its removal starts, so the sheet
/// keeps the drive it opened with, or it would go blank while the removal shows its progress.
private struct DriveSheet: View {
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
                .foregroundStyle(.red)
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
            VStack(alignment: .leading, spacing: 0) {
                Text(connection.displayName)
                if let status = drives.statusLabel(of: connection) {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
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
private struct RecoveryKitOffer: View {
    @Environment(Drives.self) private var drives
    @Environment(\.dismiss) private var dismiss

    let connection: Connection

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
                Text(problem)
                    .foregroundStyle(.red)
            }
            if isSaved {
                Label("Recovery kit saved", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Button("Done") { dismiss() }
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
                Button("Not Now") { dismiss() }
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
    /// An SFTP server's identity, shown once and trusted by the next press of the button.
    @State private var hostKey: RemoteEngine.HostKey?
    @State private var allowsInsecure = false
    @State private var isConnecting = false
    @State private var problem: String?
    @State private var browsing: FolderBrowsing?
    /// The folder has things in it, and an encrypted drive can't share one.
    @State private var needsOwnFolder = false
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

    var body: some View {
        VStack(alignment: .leading, spacing: Design.sectionGap) {
            CardSection("Server") {
                FieldRow(label: "Name", text: $form.name)
                SettingRow("Protocol") {
                    Picker("Protocol", selection: $form.kind) {
                        ForEach(ConnectionForm.Kind.allCases, id: \.self) { kind in
                            Text(kind.title)
                        }
                    }
                }
                FieldRow(label: "Host", text: $form.host, prompt: "example.com")
                FieldRow(label: "Port", text: $form.port, prompt: form.kind.defaultPort)
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
                FieldRow(label: "Folder", text: $form.path, prompt: isSFTP ? LocalizedStringKey("Home folder") : LocalizedStringKey("Top folder"))
                // On SFTP, Documents and /Documents are two places, so it says which this is.
                if let folderProblem = tidied.folderProblem {
                    Text(folderProblem)
                        .font(.caption)
                        .foregroundStyle(.red)
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
            }
            CardSection("Encryption") {
                SettingRow("Enable encryption") {
                    RowSwitch(label: "Enable encryption", isOn: $isEncrypted)
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
                Text(isEncrypted
                    ? "This can't be changed later. A lost password can't be recovered, and neither can the files. Save a recovery kit from the drive's details afterwards."
                    : "This can't be changed later.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let hostKey {
                CardSection("Server identity") {
                    Text(hostKey.fingerprint)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    Text("Check this matches your server before trusting it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if needsOwnFolder {
                CardSection("This folder isn't empty") {
                    Text("An encrypted drive needs its own folder, because it can't read what's already here. Nothing here is changed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    SettingRow("Make the folder \(tidied.ownFolderName) here") {
                        Button("Create and Connect") { connectInOwnFolder() }
                            .buttonStyle(.pill)
                            .disabled(isConnecting || tidied.ownFolderName.isEmpty)
                    }
                }
            }
            if let problem {
                Text(problem)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
        }
        .padding(16)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .fileImporter(isPresented: $isChoosingKey, allowedContentTypes: [.item], onCompletion: loadKey)
        .fileDialogBrowserOptions(.includeHiddenFiles)
        .onChange(of: serverIdentity) {
            hostKey = nil
            needsOwnFolder = false
            otherFolder = nil
        }
        .onChange(of: form.path) {
            needsOwnFolder = false
            otherFolder = nil
        }
        .sheet(item: $browsing) { session in
            ServerFolderPicker(session: session) { folder in
                form.path = session.start.folderField(for: folder)
            }
            .presentationBackground(.regularMaterial)
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(hostKey == nil ? "Connect" : "Trust and Connect") { connect() }
                    .disabled(!canConnect || isConnecting)
            }
        }
    }

    private func loadKey(_ result: Result<URL, Error>) {
        do {
            let key = try PrivateKeyFile(result)
            privateKey = key.text
            privateKeyName = key.name
            problem = nil
        } catch {
            let reason = error.localizedDescription
            problem = String(localized: "That key can't be read: \(reason)")
        }
    }

    /// The engine's path for a refusal is `/`, the drive's own folder, which reads as the server's.
    /// A server that can't be reached is checked first, so the words say which part failed.
    private func explain(_ error: Error, for connection: Connection) async -> String {
        if case RemoteError.forbidden = error {
            return String(localized: "The server refused to open this folder. Check that this user can read it. On a Mac server, Documents, Desktop and Downloads also need \"Allow full disk access for remote users\", under System Settings, General, Sharing, Remote Login.")
        }
        return await ConnectionChecks.explain(error, for: connection, device: .mac)
    }

    /// Connects to the server alone, with nothing written, to look through its folders.
    private func browse() {
        form = tidied
        let start = form.browseStart
        guard var connection = start.browsingConnection(hostKey: hostKey?.key) else {
            problem = String(localized: "Check the server's details.")
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
                // The first press only reads the server's identity, to show it.
                if case .sftp(let host, let port) = connection.endpoint, hostKey == nil {
                    hostKey = try await RemoteEngine.hostKey(host: host, port: port)
                    problem = String(localized: "Check the server's identity below, then press Browse again.")
                    return
                }
                let engine = try await RemoteEngine(connection: connection, credentials: signIn)
                browsing = FolderBrowsing(start: start, engine: engine, typed: form.typedFolder(inside: start))
            } catch {
                problem = String(localized: "Couldn't connect. Checking why…")
                let reason = await explain(error, for: connection)
                problem = String(localized: "Couldn't connect: \(reason)")
            }
        }
    }

    /// Makes a folder named after the drive inside the one chosen, and connects there.
    private func connectInOwnFolder() {
        form = tidied
        guard var connection = form.browsingConnection(hostKey: hostKey?.key),
              let folder = RemotePath.root.appending(form.ownFolderName)
        else {
            problem = String(localized: "That name can't be used for a folder.")
            return
        }
        connection.allowsInsecure = allowsInsecure
        isConnecting = true
        problem = nil
        Task {
            do {
                #if DEBUG
                guard connection.isTestDrive else { throw Drives.DriveError.notATestFolder }
                #endif
                let engine = try await RemoteEngine(connection: connection, credentials: signIn)
                try await engine.createDirectory(folder)
                form.path = form.folderField(for: folder)
                isConnecting = false
                connect()
            } catch {
                isConnecting = false
                problem = String(localized: "Couldn't connect. Checking why…")
                let reason = await explain(error, for: connection)
                problem = String(localized: "That folder couldn't be made: \(reason)")
            }
        }
    }

    private func connect() {
        form = tidied
        guard var connection = form.newConnection(isEncrypted: isEncrypted, hostKey: hostKey?.key) else {
            problem = String(localized: "Check the name and the server's details.")
            return
        }
        connection.allowsInsecure = allowsInsecure
        isConnecting = true
        problem = nil
        Task {
            defer { isConnecting = false }
            do {
                // The first press only reads the server's identity, to show it.
                if case .sftp(let host, let port) = connection.endpoint, hostKey == nil {
                    hostKey = try await RemoteEngine.hostKey(host: host, port: port)
                    return
                }
                let saved = try await drives.add(connection, credentials: signIn)
                if saved.isEncrypted {
                    addedEncryptedDrive(saved)
                }
                dismiss()
            } catch RemoteError.vault(.encrypted) {
                // The folder already holds an encrypted drive, so only its password is needed.
                isEncrypted = true
                problem = RemoteError.vault(.encrypted).localizedDescription
            } catch RemoteError.vault(.missing) {
                needsOwnFolder = true
            } catch RemoteError.notFound(let path) where path.isRoot {
                // On SFTP, Documents and /Documents are two places: the other may be the one meant.
                if let other = await RemoteEngine.otherReading(of: connection, credentials: signIn) {
                    otherFolder = other
                    problem = ServerFolder.missingFolder(connection.rootPath, other: other)
                } else {
                    problem = String(localized: "Couldn't connect: that folder isn't on the server.")
                }
            } catch {
                problem = String(localized: "Couldn't connect. Checking why…")
                let reason = await explain(error, for: connection)
                problem = String(localized: "Couldn't connect: \(reason)")
            }
        }
    }
}
