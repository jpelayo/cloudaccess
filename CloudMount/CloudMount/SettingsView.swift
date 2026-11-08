// Apache 2 license - developer@infinitecontext.com

import CloudCore
import CloudDesign
import RemoteEngine
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(Drives.self) private var drives
    @State private var isAdding = false
    @State private var sheet: DriveRequest?
    @State private var isConfirmingForgetAll = false
    @State private var loginStatus = LoginAgent.status
    @State private var diagnostics: TextFile?

    private var launchAtLogin: Binding<Bool> {
        Binding {
            loginStatus != .off
        } set: { isOn in
            LoginAgent.set(isOn)
            loginStatus = LoginAgent.status
        }
    }

    private var version: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.sectionGap) {
            // The window's close button sits to the left of this line.
            PanelHeader(title: "CloudMount", detail: version) {
                OverallPill { connection in
                    sheet = DriveRequest(driveID: connection.id, sheet: .information)
                }
            }
            .padding(.leading, 26)
            if drives.needsEnabling {
                PermissionRow("Turn on CloudMount in System Settings.") {
                    drives.openExtensionSettings()
                }
            }
            if loginStatus == .needsApproval {
                PermissionRow("Allow CloudMount in Login Items.") {
                    LoginAgent.openLoginItems()
                }
            }
            if !drives.drivesNeedingTailscale.isEmpty {
                PermissionRow(
                    "Some drives need Tailscale. Check that it's on.", button: "Open Tailscale",
                    action: drives.hasTailscale ? { drives.openTailscale() } : nil)
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
                Text("macOS has \(drives.unknownDomains.count) drive(s) that CloudMount doesn't recognise. They've been left alone.")
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
                IconRow("iphone", "CloudWander for iPhone", subtitle: "Your drives on your phone") {
                    Button("Learn More…") {
                        AppWindows.showCloudWander()
                    }
                    .buttonStyle(.pill)
                }
                IconRow("info.circle", "About CloudMount") {
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
        .sheet(isPresented: $isAdding) {
            AddDriveView()
                .presentationBackground(.regularMaterial)
        }
        .sheet(item: $sheet) { request in
            Group {
                if let connection = drives.connections.first(where: { $0.id == request.driveID }) {
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
            .presentationBackground(.regularMaterial)
        }
        .onChange(of: drives.request, initial: true) { _, request in
            guard let request else { return }
            sheet = request
            drives.request = nil
        }
        .onChange(of: drives.wantsAddForm, initial: true) { _, wanted in
            guard wanted else { return }
            isAdding = true
            drives.wantsAddForm = false
        }
        .confirmationDialog("Forget all kept files?", isPresented: $isConfirmingForgetAll) {
            Button("Forget All", role: .destructive) { drives.forgetAllPreserved() }
        } message: {
            Text("The files stay on this Mac, but CloudMount stops showing where they are.")
        }
        .savesText($diagnostics, named: "CloudMount Diagnostics.txt")
    }
}

/// Something macOS is still waiting for. It comes first, because nothing works without it.
private struct PermissionRow: View {
    let text: String
    let button: String
    let action: (() -> Void)?

    init(_ text: String, button: String = "Open System Settings", action: (() -> Void)?) {
        self.text = text
        self.button = button
        self.action = action
    }

    var body: some View {
        Card {
            HStack {
                Label(text, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Spacer()
                if let action {
                    Button(button, action: action)
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

/// A key chosen in a file panel, which only gives access for as long as it's being read.
struct PrivateKeyFile {
    let text: String
    let name: String

    init(_ result: Result<URL, Error>) throws {
        let url = try result.get()
        let isAllowed = url.startAccessingSecurityScopedResource()
        defer {
            if isAllowed { url.stopAccessingSecurityScopedResource() }
        }
        text = try String(contentsOf: url, encoding: .utf8)
        name = url.lastPathComponent
    }
}

struct AddDriveView: View {
    @Environment(Drives.self) private var drives
    @Environment(\.dismiss) private var dismiss

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
    /// A new encrypted drive, whose recovery kit is offered before this closes.
    @State private var newEncryptedDrive: Connection?
    @State private var browsing: FolderBrowsing?
    /// The folder has things in it, and an encrypted drive can't share one.
    @State private var needsOwnFolder = false

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

    private var canConnect: Bool {
        guard tidied.newConnection(isEncrypted: isEncrypted) != nil, !isEncrypted || !vaultPassword.isEmpty
        else { return false }
        return !isInsecure || allowsInsecure
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

    /// Where looking starts. A test build stays inside its test folder.
    private var browseStart: ConnectionForm {
        #if DEBUG
        tidied
        #else
        tidied.atTopFolder
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.sectionGap) {
            CardSection("Server") {
                FieldRow(label: "Name", text: $form.name)
                SettingRow("Protocol") {
                    Picker("Protocol", selection: $form.kind) {
                        ForEach(ConnectionForm.Kind.allCases, id: \.self) { kind in
                            Text(kind.rawValue)
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
                        Button(privateKeyName ?? "Choose…") { isChoosingKey = true }
                            .buttonStyle(.pill)
                    }
                    if privateKey != nil {
                        FieldRow(label: "Key passphrase", text: $keyPassphrase, prompt: "If it has one", isSecure: true)
                    }
                }
                FieldRow(label: "Folder", text: $form.path, prompt: "Top folder")
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
        }
        .padding(16)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .fileImporter(isPresented: $isChoosingKey, allowedContentTypes: [.item], onCompletion: loadKey)
        .fileDialogBrowserOptions(.includeHiddenFiles)
        .onChange(of: serverIdentity) {
            hostKey = nil
            needsOwnFolder = false
        }
        .onChange(of: form.path) {
            needsOwnFolder = false
        }
        .sheet(item: $browsing) { session in
            ServerFolderPicker(engine: session.engine) { folder in
                form.path = session.start.folderField(for: folder)
            }
            .presentationBackground(.regularMaterial)
        }
        .sheet(item: $newEncryptedDrive, onDismiss: { dismiss() }) { connection in
            RecoveryKitOffer(connection: connection)
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
            problem = "That key can't be read: \(error.localizedDescription)"
        }
    }

    /// The engine's path for a refusal is `/`, the drive's own folder, which reads as the server's.
    private func explain(_ error: Error, for endpoint: Connection.Endpoint) -> String {
        if case RemoteError.forbidden = error {
            return "The server refused to open this folder. Check that this user can read it. On a Mac server, Documents, Desktop and Downloads also need \"Allow full disk access for remote users\", under System Settings, General, Sharing, Remote Login."
        }
        return Tailnet.explain(error, for: endpoint)
    }

    /// Connects to the server alone, with nothing written, to look through its folders.
    private func browse() {
        form = tidied
        let start = browseStart
        guard var connection = start.browsingConnection(hostKey: hostKey?.key) else {
            problem = "Check the server's details."
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
                    problem = "Check the server's identity below, then press Browse again."
                    return
                }
                let engine = try await RemoteEngine(connection: connection, credentials: signIn)
                browsing = FolderBrowsing(start: start, engine: engine)
            } catch {
                problem = "Couldn't connect: \(explain(error, for: connection.endpoint))"
            }
        }
    }

    /// Makes a folder named after the drive inside the one chosen, and connects there.
    private func connectInOwnFolder() {
        form = tidied
        guard var connection = form.browsingConnection(hostKey: hostKey?.key),
              let folder = RemotePath.root.appending(form.ownFolderName)
        else {
            problem = "That name can't be used for a folder."
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
                problem = "That folder couldn't be made: \(Tailnet.explain(error, for: connection.endpoint))"
            }
        }
    }

    private func connect() {
        form = tidied
        guard var connection = form.newConnection(isEncrypted: isEncrypted, hostKey: hostKey?.key) else {
            problem = "Check the name and the server's details."
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
                    newEncryptedDrive = saved
                } else {
                    dismiss()
                }
            } catch RemoteError.vault(.encrypted) {
                // The folder already holds an encrypted drive, so only its password is needed.
                isEncrypted = true
                problem = RemoteError.vault(.encrypted).localizedDescription
            } catch RemoteError.vault(.missing) {
                needsOwnFolder = true
            } catch {
                problem = "Couldn't connect: \(explain(error, for: connection.endpoint))"
            }
        }
    }
}
