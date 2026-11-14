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
    /// A new SFTP server's identity, shown once and trusted by the next press of the button.
    @State private var hostKey: RemoteEngine.HostKey?
    @State private var allowsInsecure = false
    @State private var pendingMove: Connection?
    @State private var isSaving = false
    @State private var problem: String?
    @State private var browsing: FolderBrowsing?
    @State private var isBrowsing = false
    @State private var hasSavedKey = false

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

    /// Only a mounted drive has anything to rebuild. An ejected one is just its saved details.
    private func rebuildsDrive(_ edited: Connection) -> Bool {
        edited.requiresNewDrive(comparedTo: connection) && connection.isMounted
    }

    /// One whole message either way, so each reads right in every language.
    private var moveMessage: Text {
        guard let count = drives.waiting[connection.id], count > 0 else {
            return Text("The drive leaves Finder and comes back with what's at the new address. Everything on the current server stays there.")
        }
        return Text("\(count) files haven't uploaded yet. They'll be kept on this Mac, and Settings shows where. The drive leaves Finder and comes back with what's at the new address. Everything on the current server stays there.")
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
            FieldRow(label: "Port", text: $form.port, prompt: form.kind.defaultPort)
            FieldRow(label: "Folder", text: $form.path)
            SettingRow("Choose it on the server") {
                Button("Browse…") { browse() }
                    .buttonStyle(.pill)
                    .disabled(!canBrowse)
            }
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
            if let hostKey {
                Text(hostKey.fingerprint)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                Text("Check this matches your server, then press Save to trust it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let problem {
                Text(problem)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
                problem = String(localized: "Those details aren't valid, so nothing has been saved.")
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
            // A different address is a different server, so it can't inherit this trust.
            hostKey = nil
        }
        .confirmationDialog(
            "Move \(connection.displayName) to this address?",
            isPresented: Binding { pendingMove != nil } set: { if !$0 { pendingMove = nil } }
        ) {
            Button("Move Drive", role: .destructive) {
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
            problem = String(localized: "That key can't be read: \(reason)")
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
            problem = String(localized: "Check the server's details.")
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
                // A new server's identity is shown first, as Save does.
                if case .sftp(let host, let port) = probe.endpoint, probe.hostKey == nil {
                    hostKey = try await RemoteEngine.hostKey(host: host, port: port)
                    problem = String(localized: "Check the server's identity below, then press Browse again.")
                    return
                }
                let credentials = try drives.browsingSignIn(for: connection, editedBy: signIn)
                let engine = try await RemoteEngine(connection: probe, credentials: credentials)
                browsing = FolderBrowsing(
                    start: start, engine: engine, typed: form.typedFolder(inside: start),
                    canMake: !connection.isReadOnly)
            } catch {
                problem = String(localized: "Couldn't connect. Checking why…")
                let reason = await ConnectionChecks.explain(error, for: probe, device: .mac)
                problem = String(localized: "Couldn't connect: \(reason)")
            }
        }
    }

    private func save() {
        guard var edited = form.applied(to: connection) else { return }
        problem = nil
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                // The first press only reads a new server's identity, to show it.
                if needsConsent {
                    edited.allowsInsecure = allowsInsecure
                }
                if case .sftp(let host, let port) = edited.endpoint, edited.hostKey == nil {
                    guard let hostKey else {
                        self.hostKey = try await RemoteEngine.hostKey(host: host, port: port)
                        return
                    }
                    edited.hostKey = hostKey.key
                }
                if rebuildsDrive(edited) {
                    pendingMove = edited
                } else {
                    try await apply(edited)
                }
            } catch {
                let reason = await ConnectionChecks.explain(error, for: edited, device: .mac)
                problem = String(localized: "Not saved: \(reason)")
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
                let reason = await ConnectionChecks.explain(error, for: edited, device: .mac)
                problem = String(localized: "Not saved: \(reason)")
            }
        }
    }

    private func apply(_ edited: Connection) async throws {
        try await drives.saveEdit(of: connection, as: edited, signIn: signIn)
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
    @State private var problem: String?

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
                Text(problem)
                    .foregroundStyle(.red)
            }
            SettingRow("Check these with your server") {
                Button("Trust New Key") {
                    guard let offered else { return }
                    Task {
                        do {
                            try await drives.trustHostKey(offered.key, of: connection)
                        } catch {
                            problem = error.localizedDescription
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
                problem = await ConnectionChecks.explain(error, for: connection, device: .mac)
            }
        }
    }
}
