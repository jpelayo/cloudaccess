// Apache 2 license - developer@infinitecontext.com

import CloudCore
import CloudDesign
import RemoteEngine
import SwiftUI
import UniformTypeIdentifiers

/// How an edit ended, for the list of drives to finish.
enum DriveEditOutcome {
    /// The same drive, saved where it is.
    case updated(Connection, signInChanged: Bool)
    /// The drive points somewhere else now, under a new ID, and the old one has to go.
    case moved(from: Connection, to: Connection)
}

/// Changes a drive's name, server or sign-in, by the Mac's rules: a new name or sign-in keeps the
/// drive where it is, and a new server, folder or account sets it up again there. Nothing is
/// saved until the new details connect, and nothing on any server changes.
struct EditDriveView: View {
    let connection: Connection
    let store: DriveStore
    /// Changes other apps saved into the drive, kept only on this iPhone, which a move deletes.
    let keptChanges: Int
    let saved: (DriveEditOutcome) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var form: ConnectionForm
    @State private var password = ""
    @State private var privateKey: String?
    @State private var privateKeyName: String?
    @State private var keyPassphrase = ""
    @State private var isChoosingKey = false
    @State private var signsInWithKey = false
    @State private var allowsInsecure = false
    /// A new SFTP server's identity, shown once and trusted by the next press of the button.
    @State private var hostKey: RemoteEngine.HostKey?
    @State private var problem: String?
    @State private var isSaving = false
    @State private var confirmingMove: Connection?

    init(connection: Connection, store: DriveStore, keptChanges: Int, saved: @escaping (DriveEditOutcome) -> Void) {
        self.connection = connection
        self.store = store
        self.keptChanges = keptChanges
        self.saved = saved
        _form = State(initialValue: ConnectionForm(connection))
    }

    private var signIn: SignInEdit {
        SignInEdit(
            password: password.isEmpty ? nil : password,
            privateKeyPEM: privateKey,
            privateKeyPassphrase: privateKey == nil || keyPassphrase.isEmpty ? nil : keyPassphrase)
    }

    private var change: DriveEdit.Change {
        DriveEdit.change(
            from: connection, form: form, signIn: signIn, among: (try? store.connections()) ?? [])
    }

    private var isMove: Bool {
        if case .move = change { return true }
        return false
    }

    private var refusal: String? {
        if case .refused(let reason) = change { return reason }
        return nil
    }

    private var needsConsent: Bool {
        form.needsInsecureConsent(comparedTo: connection)
    }

    private var canSave: Bool {
        guard !isSaving, !(needsConsent && !allowsInsecure) else { return false }
        switch change {
        case .nothing, .refused: return false
        case .inPlace, .move: return true
        }
    }

    /// What a move does, said before it happens.
    private var moveNote: String {
        var note = "This points the drive at a different server, folder or account. It's set up again there: "
            + "what's downloaded on this iPhone from the old one is removed, and so is its place in the Files app. "
            + "Nothing on either server changes."
        if keptChanges > 0 {
            note += keptChanges == 1
                ? " 1 change saved into it by another app is only on this iPhone, and goes too."
                : " \(keptChanges) changes saved into it by other apps are only on this iPhone, and go too."
        }
        return note
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $form.name)
                } header: {
                    SectionLabel("Drive")
                }
                Section {
                    Picker("Protocol", selection: $form.kind) {
                        ForEach(ConnectionForm.Kind.allCases, id: \.self) { kind in
                            Text(kind.rawValue).tag(kind)
                        }
                    }
                    TextField("Host", text: $form.host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        // A whole address pasted here is read into the fields it belongs in.
                        .onSubmit { form.tidyHost() }
                    TextField("Port", text: $form.port, prompt: Text("Usual (\(form.kind.defaultPort))"))
                        .keyboardType(.numberPad)
                    TextField("Folder", text: $form.path)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Username", text: $form.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    SectionLabel("Server")
                } footer: {
                    if isMove {
                        Text(moveNote)
                    }
                }
                Section {
                    SecretField("Password", text: $password, prompt: "Unchanged")
                    if form.kind == .sftp {
                        LabeledContent("Private key") {
                            Button(privateKeyName ?? (signsInWithKey ? "Saved key" : "Choose…")) {
                                isChoosingKey = true
                            }
                        }
                        if privateKey != nil {
                            SecretField("Key passphrase", text: $keyPassphrase, prompt: "If it has one")
                        }
                    }
                } header: {
                    SectionLabel("Sign in")
                } footer: {
                    Text("Left blank, the saved password stays. It's never shown here.")
                }
                if connection.isEncrypted {
                    Section {
                        LabeledContent("Encrypted", value: "Yes")
                    } header: {
                        SectionLabel("Encryption")
                    } footer: {
                        Text("Chosen when the drive was added. It can't be changed.")
                    }
                }
                if needsConsent {
                    Toggle("Send my password unencrypted over http", isOn: $allowsInsecure)
                }
                if let hostKey {
                    Section {
                        Text(hostKey.fingerprint)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                        Text("Check this matches your server before trusting it.")
                            .foregroundStyle(.secondary)
                    } header: {
                        SectionLabel("Server identity")
                    }
                }
                if let reason = problem ?? refusal {
                    Text(reason)
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle("Edit Drive")
            .navigationBarTitleDisplayMode(.inline)
            // A different address is a different server, so it can't inherit this trust.
            .onChange(of: "\(form.kind.rawValue)|\(form.host)|\(form.port)") {
                hostKey = nil
            }
            .onChange(of: form) {
                problem = nil
            }
            .fileImporter(isPresented: $isChoosingKey, allowedContentTypes: [.item], onCompletion: loadKey)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button(hostKey == nil ? "Save" : "Trust", action: save)
                            .disabled(!canSave)
                    }
                }
            }
            .confirmationDialog(
                "Move \(connection.displayName) to this address?",
                isPresented: Binding(get: { confirmingMove != nil }, set: { if !$0 { confirmingMove = nil } }),
                titleVisibility: .visible, presenting: confirmingMove
            ) { moved in
                Button("Move Drive", role: .destructive) {
                    Task { await apply(moved, isMove: true, needsCheck: true) }
                }
            } message: { _ in
                Text(moveNote)
            }
            .task {
                signsInWithKey = (try? store.credentials(for: connection.id))?.privateKeyPEM != nil
            }
        }
    }

    private func loadKey(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let isAllowed = url.startAccessingSecurityScopedResource()
            defer {
                if isAllowed { url.stopAccessingSecurityScopedResource() }
            }
            privateKey = try String(contentsOf: url, encoding: .utf8)
            privateKeyName = url.lastPathComponent
            problem = nil
        } catch {
            problem = "That key can't be read: \(error.localizedDescription)"
        }
    }

    private func save() {
        problem = nil
        var edited: Connection
        let isMove: Bool
        let needsCheck: Bool
        switch change {
        case .nothing, .refused:
            return
        case .inPlace(let kept, let check):
            edited = kept
            isMove = false
            needsCheck = check
            // The same place, so the same server and vault: what's pinned stays pinned, and the
            // engine holds the new details to it.
            edited.hostKey = connection.hostKey
            edited.vaultID = connection.vaultID
            edited.vaultRevision = connection.vaultRevision
        case .move(let moved):
            edited = moved
            isMove = true
            needsCheck = true
        }
        if needsConsent {
            edited.allowsInsecure = allowsInsecure
        }
        let prepared = edited
        Task {
            var connecting = prepared
            // A new SFTP server shows its identity once, and the next press trusts it.
            if case .sftp(let host, let port) = connecting.endpoint, connecting.hostKey == nil {
                guard let trusted = hostKey else {
                    isSaving = true
                    defer { isSaving = false }
                    do {
                        hostKey = try await RemoteEngine.hostKey(host: host, port: port)
                    } catch {
                        problem = Tailnet.explain(error, for: connecting.endpoint)
                    }
                    return
                }
                connecting.hostKey = trusted.key
            }
            if isMove {
                confirmingMove = connecting
                return
            }
            await apply(connecting, isMove: false, needsCheck: needsCheck)
        }
    }

    /// Connects with the new details, if they need it, and saves only once they work. A move saves
    /// the new drive before the old one goes, because a password held only in memory dies with a
    /// crash.
    private func apply(_ edited: Connection, isMove: Bool, needsCheck: Bool) async {
        isSaving = true
        defer { isSaving = false }
        var edited = edited
        do {
            let credentials = signIn.applied(to: (try? store.credentials(for: connection.id)) ?? Credentials())
            if needsCheck {
                // Never creates a vault: a folder without this drive's is refused, not set up.
                let engine = try await RemoteEngine(connection: edited, credentials: credentials)
                _ = try await engine.list(.root)
                if isMove, edited.isEncrypted {
                    edited.vaultID = engine.vault?.id
                    edited.vaultRevision = engine.vault?.revision
                }
            }
            if isMove || !signIn.isEmpty {
                try store.save(credentials, for: edited.id)
            }
            try store.save(edited)
            if isMove {
                AppLog.record("\(connection.displayName): moved to another server folder")
                saved(.moved(from: connection, to: edited))
            } else {
                AppLog.record("\(edited.displayName): drive details changed")
                saved(.updated(edited, signInChanged: !signIn.isEmpty))
            }
            dismiss()
        } catch {
            AppLog.record("\(connection.displayName): edit didn't connect: \(Diagnostics.kind(of: error))")
            problem = Tailnet.explain(error, for: edited.endpoint)
        }
    }
}
