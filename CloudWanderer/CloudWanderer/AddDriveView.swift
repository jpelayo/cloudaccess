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
    /// An SFTP server's identity, shown once and trusted by the next press of the button.
    @State private var hostKey: RemoteEngine.HostKey?
    @State private var problem: String?
    @State private var isConnecting = false
    @State private var browsing: FolderBrowsing?
    /// The other reading of an SFTP folder that isn't there, when that one is.
    @State private var otherFolder: String?

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
                if problem != nil || otherFolder != nil {
                    Section {
                        if let problem {
                            Text(verbatim: problem)
                                .foregroundStyle(.red)
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
            .sheet(isPresented: $isScanning) {
                ScanSheet { scanned in
                    setup = scanned
                    problem = nil
                }
            }
            .sheet(item: $browsing) { session in
                ServerFolderPicker(session: session) { folder in
                    form.path = session.start.folderField(for: folder)
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
                        Button(action: connect) {
                            if hostKey == nil {
                                Text("Connect")
                            } else {
                                Text("Trust and Connect")
                            }
                        }
                        .disabled(!canConnect)
                    }
                }
            }
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
            form: $form, insecureConsent: $allowsInsecure, serverNote: nil, canBrowse: canBrowse, browse: browse)
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
        } header: {
            SectionLabel("Sign in")
        }
        Section {
            Toggle("Encrypted drive", isOn: $isEncrypted)
            if isEncrypted {
                SecretField("Encryption password", text: $vaultPassword)
            }
        } header: {
            SectionLabel("Encryption")
        } footer: {
            Text("Joins an encrypted drive made with CloudAccess. Encrypted drives stay out of the Files app.")
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
            problem = String(localized: "That key can't be read: \(error.localizedDescription)")
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
                problem = form.folderProblem ?? String(localized: "Check the name and the server's details.")
                return nil
            }
            connection = typed
        }
        connection.allowsInsecure = allowsInsecure
        // One folder as two drives would be two sets of copies of the same files, and a code
        // scanned twice would otherwise add its drive again.
        if let refusal = DriveEdit.addRefusal(connection, among: (try? store.connections()) ?? []) {
            problem = refusal
            return nil
        }
        return connection
    }

    /// Connects to the server alone, with nothing saved, to look through its folders.
    private func browse() {
        form = form.tidied
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
                guard connection.isTestDrive else {
                    // A test guard, so it stays English.
                    problem = "This test build only connects to a folder named \(Connection.testFolderName)."
                    return
                }
                #endif
                // The first press only reads the server's identity, to show it.
                if case .sftp(let host, let port) = connection.endpoint, hostKey == nil {
                    hostKey = try await RemoteEngine.hostKey(host: host, port: port)
                    problem = String(localized: "Check the server's identity below, then press Browse again.")
                    return
                }
                var signIn = credentials
                signIn.vaultPassword = nil
                let engine = try await RemoteEngine(connection: connection, credentials: signIn)
                browsing = FolderBrowsing(start: start, engine: engine, typed: form.typedFolder(inside: start))
            } catch {
                problem = String(localized: "Couldn't connect. Checking why…")
                let reason = await ConnectionChecks.explain(error, for: connection, device: .iPhone)
                problem = String(localized: "Couldn't connect: \(reason)")
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
                // The first press only reads the server's identity, to show it. A scanned code
                // already carries the Mac's.
                if case .sftp(let host, let port) = connection.endpoint, connection.hostKey == nil {
                    hostKey = try await RemoteEngine.hostKey(host: host, port: port)
                    return
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
                isEncrypted = true
                problem = RemoteError.vault(.encrypted).localizedDescription
            } catch RemoteError.vault(.missing), RemoteError.vault(.notCreated) {
                problem = String(localized: "This folder has no encrypted drive. CloudWanderer only joins one made with CloudAccess, so turn off Encrypted drive or choose its folder.")
            } catch RemoteError.notFound(let path) where path.isRoot {
                // On SFTP, Documents and /Documents are two places: the other may be the one meant.
                if let other = await RemoteEngine.otherReading(of: connection, credentials: credentials) {
                    otherFolder = other
                    problem = ServerFolder.missingFolder(connection.rootPath, other: other)
                } else {
                    problem = String(localized: "Couldn't connect: that folder isn't on the server.")
                }
            } catch {
                problem = String(localized: "Couldn't connect. Checking why…")
                let reason = await ConnectionChecks.explain(error, for: connection, device: .iPhone)
                problem = String(localized: "Couldn't connect: \(reason)")
            }
        }
    }
}
