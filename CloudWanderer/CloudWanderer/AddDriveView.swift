// Apache 2 license - developer@infinitecontext.com

import CloudCore
import CloudDesign
import Foundation
import RemoteEngine
import SwiftUI
import UniformTypeIdentifiers

/// Adds a drive from a scanned code, which leaves only the passwords to enter, or by hand, with
/// the same fields and rules as the Mac: WebDAV or SFTP, any port, any folder.
struct AddDriveView: View {
    let store: DriveStore

    @Environment(\.dismiss) private var dismiss
    @State private var setup: ConnectionSetup?
    @State private var isScanning = false
    @State private var form = ConnectionForm()
    @State private var password = ""
    @State private var isEncrypted = false
    @State private var vaultPassword = ""
    @State private var privateKey: String?
    @State private var privateKeyName: String?
    @State private var keyPassphrase = ""
    @State private var isChoosingKey = false
    @State private var allowsInsecure = false
    /// An SFTP server's identity, once a person has trusted it.
    @State private var hostKey: RemoteEngine.HostKey?
    /// A new server's identity, waiting to be trusted.
    @State private var askingTrust: PendingTrust?
    @State private var problem: FormNote?
    @State private var isConnecting = false
    @State private var browsing: FolderBrowsing?
    /// The other reading of an SFTP folder that isn't there, when that one is.
    @State private var otherFolder: String?
    /// What the folder holds, and the server, account and folder it was read for, so a reading
    /// never outlives the fields it was made from.
    @State private var folderCheck: (key: String, contents: FolderContents)?

    /// The server, account and folder a reading of the folder belongs to.
    private var folderKey: String {
        "\(form.kind.rawValue) \(form.host) \(form.port) \(form.username) \(form.path)"
    }

    private var folderContents: FolderContents? {
        folderCheck.flatMap { $0.key == folderKey ? $0.contents : nil }
    }

    /// The same rule as the Mac's add form.
    private var encryptionChoice: EncryptionChoice {
        EncryptionChoice.for(folderContents, device: .iPhone)
    }

    private var needsEncryptionPassword: Bool {
        setup?.isEncrypted ?? isEncrypted
    }

    private var needsPrivateKey: Bool {
        setup?.signsInWithKey ?? false
    }

    private var isSFTP: Bool {
        form.tidied.kind == .sftp
    }

    /// Basic sign-in over http sends the password readably, so it's never done silently, and a
    /// scanned code can't skip this.
    private var isInsecure: Bool {
        if let setup {
            return setup.endpoint.isInsecure
        }
        return form.tidied.kind == .http
    }

    private var canConnect: Bool {
        if isConnecting { return false }
        guard let setup else {
            return form.canConnect(
                isEncrypted: isEncrypted, hasVaultPassword: !vaultPassword.isEmpty, allowsInsecure: allowsInsecure)
        }
        if setup.endpoint.isInsecure && !allowsInsecure { return false }
        if needsEncryptionPassword && vaultPassword.isEmpty { return false }
        return !needsPrivateKey || privateKey != nil
    }

    private var canBrowse: Bool {
        !isConnecting && form.tidied.browsingConnection() != nil && (!isInsecure || allowsInsecure)
    }

    private var credentials: Credentials {
        Credentials(
            password: password.isEmpty ? nil : password,
            privateKeyPEM: privateKey,
            privateKeyPassphrase: keyPassphrase.isEmpty ? nil : keyPassphrase,
            vaultPassword: needsEncryptionPassword ? vaultPassword : nil)
    }

    /// Which server these fields reach. A different one can't inherit a trusted identity.
    private var serverIdentity: String {
        let tidy = form.tidied
        return "\(tidy.kind.rawValue)|\(tidy.host)|\(tidy.port)"
    }

    var body: some View {
        NavigationStack {
            Form {
                if let setup {
                    scanned(setup)
                } else {
                    typed
                }
                if problem.map({ [ConnectionFinding.Field.server, .thisDevice].contains($0.field) }) == true || otherFolder != nil {
                    Section {
                        if let problem, [ConnectionFinding.Field.server, .thisDevice].contains(problem.field) {
                            FieldNote(problem)
                        }
                        if let otherFolder {
                            Button {
                                form.path = otherFolder
                                self.otherFolder = nil
                                problem = nil
                            } label: {
                                Label {
                                    Text("Use \(ServerFolder.shown(otherFolder))")
                                } icon: {
                                    Image(systemName: "folder")
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Add Drive")
            .navigationBarTitleDisplayMode(.inline)
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
            .task(id: "\(folderKey) \(hostKey?.key ?? "") \(password.isEmpty) \(privateKey != nil)") {
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled else { return }
                await checkFolder()
            }
            .sheet(isPresented: $isScanning) {
                ScanSheet { scanned in
                    setup = scanned
                    problem = nil
                }
            }
            .sheet(item: $browsing) { session in
                ServerFolderPicker(session: session) { folder in
                    form.path = session.start.folderField(for: folder)
                    Task { await checkFolder() }
                }
            }
            .fileImporter(isPresented: $isChoosingKey, allowedContentTypes: [.item], onCompletion: loadKey)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isConnecting {
                        ProgressView()
                    } else {
                        Button("Connect", action: connect)
                            .disabled(!canConnect)
                    }
                }
            }
            .trustingServer($askingTrust) { hostKey = $0 }
        }
    }

    /// Nothing connects until the person has seen where this code leads.
    @ViewBuilder
    private func scanned(_ setup: ConnectionSetup) -> some View {
        Section {
            LabeledContent("Name", value: setup.name)
            LabeledContent("Server", value: ConnectionSummary.address(of: setup.connection()))
            if let place = ServerFolder.shownPlace(of: setup.connection()) {
                LabeledContent("Folder", value: place)
            }
            if !setup.username.isEmpty {
                LabeledContent("Username", value: setup.username)
            }
        } header: {
            SectionLabel("Drive")
        }
        Section {
            ForEach(setup.neededSecrets, id: \.self) { secret in
                switch secret {
                case .serverPassword:
                    SecretField("Server password", text: $password)
                case .encryptionPassword:
                    SecretField("Encryption password", text: $vaultPassword)
                case .privateKey:
                    LabeledContent("Private key") {
                        keyButton
                    }
                    if privateKey != nil {
                        SecretField("Key passphrase", text: $keyPassphrase, prompt: "If it has one")
                    }
                }
            }
            if setup.endpoint.isInsecure {
                Toggle("Send my password unencrypted over http", isOn: $allowsInsecure)
            }
        } header: {
            SectionLabel("Sign in")
        }
        Section {
            // Keeps what the code gave, so only what differs needs typing.
            Button("Enter Details by Hand", systemImage: "keyboard") {
                form = ConnectionForm(setup.connection())
                isEncrypted = setup.isEncrypted
                self.setup = nil
                hostKey = nil
                problem = nil
            }
        }
    }

    @ViewBuilder
    private var typed: some View {
        Section {
            Button("Scan QR Code", systemImage: "qrcode.viewfinder") { isScanning = true }
        } footer: {
            Text("On your Mac, open CloudAccess and choose the QR icon beside the drive.")
        }
        Section {
            TextField("Name", text: $form.name)
        } header: {
            SectionLabel("Drive")
        }
        DriveFormFields(
            form: $form, insecureConsent: $allowsInsecure, serverNote: nil, canBrowse: canBrowse, browse: browse,
            problem: problem)
        Section {
            SecretField("Password", text: $password)
            if isSFTP {
                LabeledContent("Private key") {
                    keyButton
                }
                if privateKey != nil {
                    SecretField("Key passphrase", text: $keyPassphrase, prompt: "If it has one")
                }
            }
            if let problem, problem.field == .signIn {
                FieldNote(problem)
            }
        } header: {
            SectionLabel("Sign in")
        }
        Section {
            // A folder that can't be encrypted greys the whole section out, with the reason under it.
            Group {
                Toggle("Encrypted drive", isOn: $isEncrypted)
                    .disabled(encryptionChoice.lockedValue != nil)
                if isEncrypted {
                    SecretField("Encryption password", text: $vaultPassword)
                }
            }
            .disabled(encryptionChoice.lockedValue == false)
            .opacity(encryptionChoice.lockedValue == false ? 0.4 : 1)
        } header: {
            SectionLabel("Encryption")
        } footer: {
            if let reason = encryptionChoice.reason {
                Text(reason)
            } else {
                Text("Joins an encrypted drive made with CloudAccess. Encrypted drives stay out of the Files app.")
            }
        }
    }

    /// The chosen key's file name, which is shown as it is, or a word to choose one.
    private var keyButton: some View {
        Button {
            isChoosingKey = true
        } label: {
            if let privateKeyName {
                Text(verbatim: privateKeyName)
            } else {
                Text("Choose…")
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
            problem = FormNote(String(localized: "That key can't be read: \(error.localizedDescription)"), field: .signIn)
        }
    }

    /// The drive these fields describe, or the scanned one, with every rule of adding checked
    /// before anything connects.
    private func connectionToTry() -> Connection? {
        var connection: Connection
        if let setup {
            connection = setup.connection()
        } else {
            form = form.tidied
            guard let typed = form.newConnection(isEncrypted: isEncrypted, hostKey: hostKey?.key) else {
                problem = form.folderProblem.map { FormNote($0, field: .folder) }
                    ?? FormNote(String(localized: "Check the name and the server's details."), field: .address)
                return nil
            }
            connection = typed
        }
        connection.allowsInsecure = allowsInsecure
        // One folder as two drives would be two sets of copies of the same files, and a code
        // scanned twice would otherwise add its drive again.
        if let refusal = DriveEdit.addRefusal(connection, among: (try? store.connections()) ?? []) {
            problem = FormNote(refusal)
            return nil
        }
        return connection
    }

    /// Reads what the folder holds, so the encryption switch shows only what's possible there. It
    /// needs a trusted server and a sign-in, and writes nothing. A failure leaves the switch free,
    /// and Connect says what's wrong. A scanned code already says whether the drive is encrypted.
    private func checkFolder() async {
        let key = folderKey
        guard setup == nil, folderCheck?.key != key, !password.isEmpty || privateKey != nil,
              !isInsecure || allowsInsecure,
              var probe = form.tidied.browsingConnection(hostKey: hostKey?.key)
        else { return }
        // An SFTP server is only signed in to once its identity is trusted.
        if case .sftp = probe.endpoint, probe.hostKey == nil { return }
        #if DEBUG
        guard probe.isTestDrive else { return }
        #endif
        probe.allowsInsecure = allowsInsecure
        var signIn = credentials
        signIn.vaultPassword = nil
        guard let contents = try? await RemoteEngine.folderContents(of: probe, credentials: signIn),
              key == folderKey
        else { return }
        folderCheck = (key, contents)
    }

    /// Connects to the server alone, with nothing saved, to look through its folders.
    private func browse() {
        form = form.tidied
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
                guard connection.isTestDrive else {
                    // A test guard, so it stays English.
                    problem = FormNote("This test build only connects to a folder named \(Connection.testFolderName).")
                    return
                }
                #endif
                // A new server is trusted once, and Browse carries on after.
                if case .sftp(let host, let port) = connection.endpoint, hostKey == nil {
                    let offered = try await ServerTrust.offered(
                        host: host, port: port, among: (try? store.connections()) ?? [])
                    guard !offered.mustAsk else {
                        askingTrust = PendingTrust(host: host, key: offered.key, resume: browse)
                        return
                    }
                    hostKey = offered.key
                    connection.hostKey = offered.key.key
                }
                var signIn = credentials
                signIn.vaultPassword = nil
                let engine = try await RemoteEngine(connection: connection, credentials: signIn)
                browsing = FolderBrowsing(start: start, engine: engine, typed: form.typedFolder(inside: start))
            } catch {
                problem = FormNote(String(localized: "Couldn't connect. Checking why…"))
                problem = await ConnectionChecks.note(for: error, connection: connection, device: .iPhone)
            }
        }
    }

    private func connect() {
        problem = nil
        otherFolder = nil
        guard var connection = connectionToTry() else { return }
        isConnecting = true
        Task {
            defer { isConnecting = false }
            do {
                // A new server is trusted once, and Connect carries on after. A scanned code
                // already carries the Mac's.
                if case .sftp(let host, let port) = connection.endpoint, connection.hostKey == nil {
                    let offered = try await ServerTrust.offered(
                        host: host, port: port, among: (try? store.connections()) ?? [])
                    guard !offered.mustAsk else {
                        askingTrust = PendingTrust(host: host, key: offered.key, resume: connect)
                        return
                    }
                    hostKey = offered.key
                    connection.hostKey = offered.key.key
                }
                let signIn = credentials
                // Verifies the password against the vault marker, and that the folder can be
                // read, before saving anything. The iPhone never creates a vault.
                let engine = try await RemoteEngine(connection: connection, credentials: signIn)
                _ = try await engine.list(.root)
                connection.vaultID = engine.vault?.id
                connection.vaultRevision = engine.vault?.revision
                try store.save(signIn, for: connection.id)
                try store.save(connection)
                dismiss()
            } catch RemoteError.vault(.encrypted) {
                // The folder already holds an encrypted drive, so only its password is needed.
                // The switch turns on, with the reason under it.
                folderCheck = (folderKey, .encryptedDrive)
            } catch RemoteError.vault(.missing) {
                folderCheck = (folderKey, .plainFiles)
            } catch RemoteError.vault(.notCreated) {
                folderCheck = (folderKey, .empty)
            } catch RemoteError.notFound(let path) where path.isRoot {
                // On SFTP, Documents and /Documents are two places: the other may be the one meant.
                if let other = await RemoteEngine.otherReading(of: connection, credentials: credentials) {
                    otherFolder = other
                    problem = FormNote(ServerFolder.missingFolder(connection.rootPath, other: other), field: .folder)
                } else {
                    problem = FormNote(String(localized: "Couldn't connect: that folder isn't on the server."), field: .folder)
                }
            } catch {
                problem = FormNote(String(localized: "Couldn't connect. Checking why…"))
                problem = await ConnectionChecks.note(for: error, connection: connection, device: .iPhone)
            }
        }
    }
}
