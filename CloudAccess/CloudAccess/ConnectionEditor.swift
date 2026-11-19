// Apache 2 license - developer@infinitecontext.com

import CloudCore
import CloudDesign
import RemoteEngine
import SwiftUI
import UniformTypeIdentifiers

/// How a drive reaches its server, at the top of its General page. A new name or password changes
/// the drive where it is. Anything that points it somewhere else makes a new drive, because what
/// macOS holds for it describes the old location.
struct ConnectionEditor: View {
    @Environment(Drives.self) private var drives

    let connection: Connection
    /// Goes up by one each time the sheet's Save button is pressed.
    let saveRequests: Int
    /// Tells the sheet there's something to lose, so closing it can't drop an edit in silence.
    @Binding var hasUnsavedEdits: Bool
    /// The edit is saved and the sheet can close. A move has also taken away the drive it shows.
    let finished: () -> Void

    @State private var form: ConnectionForm
    @State private var password = ""
    @State private var privateKey: String?
    @State private var privateKeyName: String?
    @State private var keyPassphrase = ""
    @State private var isChoosingKey = false
    /// A new SFTP server's identity, once a person has trusted it.
    @State private var hostKey: RemoteEngine.HostKey?
    /// A new server's identity, waiting to be trusted.
    @State private var askingTrust: PendingTrust?
    @State private var allowsInsecure = false
    @State private var pendingMove: Connection?
    @State private var isSaving = false
    @State private var problem: FormNote?
    @State private var browsing: FolderBrowsing?
    @State private var isBrowsing = false
    @State private var hasSavedKey = false
    /// Connecting at the new address found another server, so only a move can follow.
    @State private var isDifferentServer = false

    init(
        connection: Connection, saveRequests: Int, hasUnsavedEdits: Binding<Bool>,
        finished: @escaping () -> Void
    ) {
        self.connection = connection
        self.saveRequests = saveRequests
        _hasUnsavedEdits = hasUnsavedEdits
        self.finished = finished
        _form = State(initialValue: ConnectionForm(connection))
    }

    private var signIn: SignInEdit {
        SignInEdit(
            password: password.isEmpty ? nil : password,
            privateKeyPEM: privateKey,
            privateKeyPassphrase: keyPassphrase.isEmpty ? nil : keyPassphrase)
    }

    private var hasChanges: Bool {
        form != ConnectionForm(connection) || !signIn.isEmpty
    }

    private var needsConsent: Bool {
        form.needsInsecureConsent(comparedTo: connection)
    }

    private var canBrowse: Bool {
        !isBrowsing && !isSaving && form.tidied.browsingConnection() != nil && (!needsConsent || allowsInsecure)
    }

    private var canSave: Bool {
        hasChanges && !isSaving && form.applied(to: connection) != nil && (!needsConsent || allowsInsecure)
    }

    private var statusLabel: String {
        if isSaving { return String(localized: "Checking the connection…") }
        return form.applied(to: connection) == nil
            ? String(localized: "Those details aren't valid")
            : String(localized: "Not saved yet")
    }

    /// The chosen key's file name, as it is, or what the button does. Whether the drive already has
    /// a key is read from the keychain once, when the page opens, not on every redraw.
    private var keyButtonTitle: String {
        if let privateKeyName { return privateKeyName }
        return hasSavedKey ? String(localized: "Replace…") : String(localized: "Choose…")
    }

    /// The problem, if it's about one of these fields, as one calm line under them.
    @ViewBuilder
    private func note(for fields: [ConnectionFinding.Field]) -> some View {
        if let problem, fields.contains(problem.field) {
            FieldNote(problem)
        }
    }

    /// The same server at a new address, which connecting with its key or vault will prove. It
    /// stays the same drive, so nothing is rebuilt and nothing is asked.
    private func isNewAddress(_ edited: Connection) -> Bool {
        !isDifferentServer && edited.isOnlyNewAddress(comparedTo: connection) && edited.canProveItsServer
    }

    /// Only a mounted drive has anything to rebuild. An ejected one is just its saved details.
    private func rebuildsDrive(_ edited: Connection) -> Bool {
        edited.requiresNewDrive(comparedTo: connection) && connection.isMounted && !isNewAddress(edited)
    }

    /// One whole message either way, so each reads right in every language.
    private var moveMessage: Text {
        guard let count = drives.waiting[connection.id], count > 0 else {
            return Text("The server, folder or account is different, so the drive is set up again from what's there. Nothing is deleted on either server.")
        }
        return Text("\(count) files haven't uploaded yet. They're kept on this Mac, and Settings shows where. The drive is set up again from what's there, and nothing is deleted on either server.")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if drives.changedHostKeys.contains(connection.id) {
                HostKeyReview(connection: connection)
            }
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
            FieldRow(label: "Host", text: $form.host)
            if let moved = drives.movedAddress(of: connection), form.host == ConnectionForm(connection).host {
                FieldNote(
                    String(localized: "This server's Tailscale address changed to \(moved)."),
                    actionTitle: "Use New Address"
                ) {
                    form.host = moved
                    save()
                }
            }
            FieldRow(label: "Port", text: $form.port, prompt: form.kind.defaultPort)
            note(for: [.address, .port])
            FieldRow(label: "Folder", text: $form.path)
            SettingRow("Choose it on the server") {
                Button("Browse…") { browse() }
                    .buttonStyle(.pill)
                    .disabled(!canBrowse)
            }
            note(for: [.folder])
            FieldRow(label: "User", text: $form.username)
            FieldRow(label: "Password", text: $password, prompt: "Unchanged", isSecure: true)
            if form.kind == .sftp {
                SettingRow("Private key") {
                    Button(keyButtonTitle) {
                        isChoosingKey = true
                    }
                    .buttonStyle(.pill)
                }
                if privateKey != nil {
                    FieldRow(label: "Key passphrase", text: $keyPassphrase, prompt: "If it has one", isSecure: true)
                }
            }
            note(for: [.signIn])
            SettingRow("Encryption") {
                Text(connection.isEncrypted ? "On" : "Off")
                    .foregroundStyle(.secondary)
                    .help("Chosen when the drive was added. It can't be changed.")
            }
            if needsConsent {
                SettingRow("Send my password unencrypted over http") {
                    RowSwitch(label: "Send my password unencrypted over http", isOn: $allowsInsecure)
                }
            }
            note(for: [.server, .thisDevice])
            if hasChanges || isSaving {
                Text(statusLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onChange(of: hasChanges, initial: true) {
            hasUnsavedEdits = hasChanges
        }
        .task(id: connection.id) {
            if case .sftp = connection.endpoint {
                hasSavedKey = drives.signsInWithKey(connection)
            }
        }
        .onChange(of: saveRequests) {
            if canSave {
                save()
            } else if !isSaving {
                problem = FormNote(String(localized: "Those details aren't valid, so nothing has been saved."))
            }
        }
        .fileImporter(isPresented: $isChoosingKey, allowedContentTypes: [.item], onCompletion: loadKey)
        .fileDialogBrowserOptions(.includeHiddenFiles)
        .sheet(item: $browsing) { session in
            ServerFolderPicker(session: session) { folder in
                form.path = session.start.folderField(for: folder)
            }
            .presentationBackground(.regularMaterial)
            .presentationSizing(.fitted)
        }
        .onChange(of: [form.kind.rawValue, form.host, form.port]) {
            // A key offered by one address isn't trusted for another. The drive's own key stays in
            // its details, and connecting with it proves whether a new address is the same server.
            hostKey = nil
            isDifferentServer = false
        }
        .trustingServer($askingTrust) { hostKey = $0 }
        .confirmationDialog(
            "Set up \(connection.displayName) again here?",
            isPresented: Binding { pendingMove != nil } set: { if !$0 { pendingMove = nil } }
        ) {
            Button("Set Up Again", role: .destructive) {
                if let pendingMove {
                    commit(pendingMove)
                }
            }
        } message: {
            moveMessage
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
            problem = FormNote(String(localized: "That key can't be read: \(reason)"), field: .signIn)
        }
    }

    /// Connects to the server as the fields now say, with nothing saved, to choose a folder from
    /// its tree. The chosen folder fills the field, and Save moves the drive as for a typed one.
    private func browse() {
        form = form.tidied
        let start = form.browseStart
        // The server's saved identity still holds while host and port are unchanged.
        let knownKey = hostKey?.key ?? form.applied(to: connection)?.hostKey
        guard var probe = start.browsingConnection(hostKey: knownKey) else {
            problem = FormNote(String(localized: "Check the server's details."), field: .address)
            return
        }
        probe.allowsInsecure = needsConsent ? allowsInsecure : connection.allowsInsecure
        isBrowsing = true
        problem = nil
        Task {
            defer { isBrowsing = false }
            do {
                #if DEBUG
                guard probe.isTestDrive else { throw Drives.DriveError.notATestFolder }
                #endif
                // A new server is trusted once, and Browse carries on after.
                if case .sftp(let host, let port) = probe.endpoint, probe.hostKey == nil {
                    let offered = try await ServerTrust.offered(host: host, port: port, among: drives.connections)
                    guard !offered.mustAsk else {
                        askingTrust = PendingTrust(host: host, key: offered.key, resume: browse)
                        return
                    }
                    hostKey = offered.key
                    probe.hostKey = offered.key.key
                }
                let credentials = try drives.browsingSignIn(for: connection, editedBy: signIn)
                let engine = try await RemoteEngine(connection: probe, credentials: credentials)
                browsing = FolderBrowsing(
                    start: start, engine: engine, typed: form.typedFolder(inside: start),
                    canMake: !connection.isReadOnly)
            } catch {
                problem = FormNote(String(localized: "Couldn't connect. Checking why…"))
                problem = await ConnectionChecks.note(for: error, connection: probe, device: .mac)
            }
        }
    }

    private func save() {
        guard var edited = form.applied(to: connection) else { return }
        if isDifferentServer {
            // Another server: the old one's key and vault don't belong to it.
            if edited.endpoint != connection.endpoint {
                edited.hostKey = nil
            }
            edited.vaultID = nil
            edited.vaultRevision = nil
        }
        problem = nil
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                if needsConsent {
                    edited.allowsInsecure = allowsInsecure
                }
                // A new server is trusted once, and Save carries on after.
                if case .sftp(let host, let port) = edited.endpoint, edited.hostKey == nil {
                    if hostKey == nil {
                        let offered = try await ServerTrust.offered(host: host, port: port, among: drives.connections)
                        guard !offered.mustAsk else {
                            askingTrust = PendingTrust(host: host, key: offered.key, resume: save)
                            return
                        }
                        hostKey = offered.key
                    }
                    edited.hostKey = hostKey?.key
                }
                if rebuildsDrive(edited) {
                    pendingMove = edited
                } else {
                    try await apply(edited)
                }
            } catch Drives.DriveError.differentServer {
                isDifferentServer = true
                problem = FormNote(Drives.DriveError.differentServer.localizedDescription, field: .address)
            } catch {
                problem = await ConnectionChecks.note(for: error, connection: edited, device: .mac)
            }
        }
    }

    private func commit(_ edited: Connection) {
        problem = nil
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                try await apply(edited)
            } catch {
                problem = await ConnectionChecks.note(for: error, connection: edited, device: .mac)
            }
        }
    }

    private func apply(_ edited: Connection) async throws {
        try await drives.saveEdit(of: connection, as: edited, signIn: signIn, mayKeepAtNewAddress: !isDifferentServer)
        password = ""
        privateKey = nil
        privateKeyName = nil
        keyPassphrase = ""
        hostKey = nil
        allowsInsecure = false
        finished()
    }
}

/// Shows a server's old and new keys side by side. A changed key can mean the server was
/// reinstalled, or that it isn't your server, and only a person can tell which.
private struct HostKeyReview: View {
    @Environment(Drives.self) private var drives

    let connection: Connection

    @State private var saved: RemoteEngine.HostKey?
    @State private var offered: RemoteEngine.HostKey?
    @State private var problem: FormNote?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("This server's identity has changed.", systemImage: "exclamationmark.shield.fill")
                .foregroundStyle(.red)
            Text("It may have been reinstalled, or it may not be your server. Nothing connects until you decide.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            KeyValueRow(String(localized: "Saved"), saved?.fingerprint ?? "…")
            KeyValueRow(String(localized: "Now offered"), offered?.fingerprint ?? "…")
            if let problem {
                FieldNote(problem)
            }
            SettingRow("Check these with your server") {
                Button("Trust New Key") {
                    guard let offered else { return }
                    Task {
                        do {
                            try await drives.trustHostKey(offered.key, of: connection)
                        } catch {
                            problem = FormNote.forError(error)
                        }
                    }
                }
                .buttonStyle(.pill)
                .disabled(offered == nil)
            }
            Divider()
        }
        .task {
            if let key = connection.hostKey {
                saved = try? await RemoteEngine.hostKeyDetails(key: key)
            }
            guard case .sftp(let host, let port) = connection.endpoint else { return }
            do {
                offered = try await RemoteEngine.hostKey(host: host, port: port)
            } catch {
                problem = await ConnectionChecks.note(for: error, connection: connection, device: .mac)
            }
        }
    }
}
