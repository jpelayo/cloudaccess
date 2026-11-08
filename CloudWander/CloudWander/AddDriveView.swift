// Apache 2 license - developer@infinitecontext.com

import CloudCore
import CloudDesign
import RemoteEngine
import SwiftUI
import UniformTypeIdentifiers

/// Adds a drive from a scanned code, which leaves only the passwords to enter, or by hand.
struct AddDriveView: View {
    let store: DriveStore

    @Environment(\.dismiss) private var dismiss
    @State private var setup: ConnectionSetup?
    @State private var isScanning = false
    @State private var name = ""
    @State private var address = ""
    @State private var username = ""
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

    private var needsEncryptionPassword: Bool {
        setup?.isEncrypted ?? isEncrypted
    }

    private var needsPrivateKey: Bool {
        setup?.signsInWithKey ?? false
    }

    private var isSFTP: Bool {
        if case .sftp = ServerAddress(address)?.endpoint { return true }
        return false
    }

    /// Basic sign-in over http sends the password readably, so it's never done silently, and a
    /// scanned code can't skip this.
    private var isInsecure: Bool {
        if let setup {
            return setup.endpoint.isInsecure
        }
        return ServerAddress(address)?.isInsecure == true
    }

    private var canConnect: Bool {
        if isConnecting { return false }
        if isInsecure && !allowsInsecure { return false }
        if needsEncryptionPassword && vaultPassword.isEmpty { return false }
        if needsPrivateKey && privateKey == nil { return false }
        return setup != nil || (!name.isEmpty && !address.isEmpty)
    }

    var body: some View {
        NavigationStack {
            Form {
                if let setup {
                    scanned(setup)
                } else {
                    typed
                }
                if isInsecure {
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
                if let problem {
                    Text(problem)
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle("Add Drive")
            .onChange(of: address) {
                // A different address is a different server, so it can't inherit this trust.
                hostKey = nil
            }
            .sheet(isPresented: $isScanning) {
                ScanSheet { scanned in
                    setup = scanned
                    problem = nil
                }
            }
            .fileImporter(isPresented: $isChoosingKey, allowedContentTypes: [.item], onCompletion: loadKey)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(hostKey == nil ? "Connect" : "Trust", action: connect)
                        .disabled(!canConnect)
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
                        Button(privateKeyName ?? "Choose…") { isChoosingKey = true }
                    }
                    if privateKey != nil {
                        SecretField("Key passphrase", text: $keyPassphrase, prompt: "If it has one")
                    }
                }
            }
        } header: {
            SectionLabel("Sign in")
        }
    }

    @ViewBuilder
    private var typed: some View {
        Section {
            Button("Scan QR Code", systemImage: "qrcode.viewfinder") { isScanning = true }
        } footer: {
            Text("On your Mac, open CloudMount and choose the QR icon beside the drive.")
        }
        Section {
            TextField("Name", text: $name)
            TextField("Address", text: $address)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
            TextField("Username", text: $username)
                .textInputAutocapitalization(.never)
            SecretField("Password", text: $password)
            if isSFTP {
                LabeledContent("Private key") {
                    Button(privateKeyName ?? "Choose…") { isChoosingKey = true }
                }
                if privateKey != nil {
                    SecretField("Key passphrase", text: $keyPassphrase, prompt: "If it has one")
                }
            }
        } header: {
            SectionLabel("Server")
        }
        Section {
            Toggle("Encrypted drive", isOn: $isEncrypted)
            if isEncrypted {
                SecretField("Encryption password", text: $vaultPassword)
            }
        } header: {
            SectionLabel("Encryption")
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

    /// The connection to try. A typed SFTP address returns nil the first time, once it has
    /// fetched the server's identity to show. A scanned code already carries the Mac's pin.
    private func connectionToTry() async throws -> Connection? {
        if let setup { return setup.connection() }
        guard let server = ServerAddress(address) else {
            problem = "That address isn't valid."
            return nil
        }
        if case .sftp(let host, let port) = server.endpoint, hostKey == nil {
            hostKey = try await RemoteEngine.hostKey(host: host, port: port)
            return nil
        }
        return Connection(
            displayName: name,
            endpoint: server.endpoint,
            username: username,
            rootPath: server.rootPath,
            isEncrypted: isEncrypted,
            hostKey: hostKey?.key)
    }

    private func connect() {
        isConnecting = true
        problem = nil
        Task {
            defer { isConnecting = false }
            do {
                guard var connection = try await connectionToTry() else { return }
                connection.allowsInsecure = allowsInsecure
                #if DEBUG
                guard connection.isTestDrive else {
                    problem = "This test build only connects to a folder named \(Connection.testFolderName)."
                    return
                }
                #endif
                // One folder as two drives would be two sets of copies of the same files, and a
                // code scanned twice would otherwise add its drive again.
                if let clash = DriveEdit.clash(connection, among: (try? store.connections()) ?? []) {
                    problem = clash.reason
                    return
                }
                let credentials = Credentials(
                    password: password.isEmpty ? nil : password,
                    privateKeyPEM: privateKey,
                    privateKeyPassphrase: keyPassphrase.isEmpty ? nil : keyPassphrase,
                    vaultPassword: needsEncryptionPassword ? vaultPassword : nil)
                // Verifies the password against the vault marker before saving anything.
                let engine = try await RemoteEngine(connection: connection, credentials: credentials)
                connection.vaultID = engine.vault?.id
                connection.vaultRevision = engine.vault?.revision
                try store.save(credentials, for: connection.id)
                try store.save(connection)
                dismiss()
            } catch RemoteError.vault(.encrypted) {
                // The folder already holds an encrypted drive, so only its password is needed.
                isEncrypted = true
                problem = RemoteError.vault(.encrypted).localizedDescription
            } catch {
                let endpoint = setup?.connection().endpoint ?? ServerAddress(address)?.endpoint
                problem = endpoint.map { Tailnet.explain(error, for: $0) } ?? error.localizedDescription
            }
        }
    }
}
