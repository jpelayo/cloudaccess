// Apache 2 license - developer@infinitecontext.com

import CloudCore
import CloudDesign
import RemoteEngine
import SwiftUI
import UniformTypeIdentifiers

/// Signs in to a drive again, which is where iOS sends a person whose drive in Files asks for it.
/// The new password is checked with the server before anything is saved, and saving it puts it
/// where the Files extension reads it.
struct SignInView: View {
    let connection: Connection
    let store: DriveStore
    let signedIn: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var saved: Credentials?
    @State private var password = ""
    @State private var privateKey: String?
    @State private var privateKeyName: String?
    @State private var keyPassphrase = ""
    @State private var isChoosingKey = false
    @State private var problem: String?
    @State private var isConnecting = false

    private var isSFTP: Bool {
        if case .sftp = connection.endpoint { return true }
        return false
    }

    /// A drive that signs in with a key asks for the key, and anything else for a password. If
    /// nothing saved says which, an SFTP drive can take either.
    private var usesKey: Bool {
        saved?.privateKeyPEM != nil
    }

    private var asksForPassword: Bool {
        !usesKey
    }

    private var asksForKey: Bool {
        usesKey || (isSFTP && saved == nil)
    }

    private var canSignIn: Bool {
        !isConnecting && (!password.isEmpty || privateKey != nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Drive", value: connection.displayName)
                    LabeledContent("Server", value: ConnectionSummary.address(of: connection))
                    if !connection.username.isEmpty {
                        LabeledContent("Username", value: connection.username)
                    }
                } header: {
                    SectionLabel("Drive")
                }
                Section {
                    if asksForPassword {
                        SecretField("Password", text: $password)
                    }
                    if asksForKey {
                        LabeledContent("Private key") {
                            Button(privateKeyName ?? "Choose…") { isChoosingKey = true }
                        }
                        if privateKey != nil {
                            SecretField("Key passphrase", text: $keyPassphrase, prompt: "If it has one")
                        }
                    }
                } header: {
                    SectionLabel("Sign in")
                } footer: {
                    Text("CloudWanderer checks it with the server first. Then the Files app uses it too.")
                }
                if let problem {
                    Text(problem)
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle("Sign In")
            .navigationBarTitleDisplayMode(.inline)
            .fileImporter(isPresented: $isChoosingKey, allowedContentTypes: [.item], onCompletion: loadKey)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isConnecting {
                        ProgressView()
                    } else {
                        Button("Sign In", action: signIn)
                            .disabled(!canSignIn)
                    }
                }
            }
            .task {
                saved = try? store.credentials(for: connection.id)
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

    /// Keeps whatever else was saved, such as an encryption password, and changes only what
    /// was typed. Nothing is saved unless the server lists the drive with it.
    private func signIn() {
        isConnecting = true
        problem = nil
        var credentials = saved ?? Credentials()
        if !password.isEmpty {
            credentials.password = password
        }
        if let privateKey {
            credentials.privateKeyPEM = privateKey
            credentials.privateKeyPassphrase = keyPassphrase.isEmpty ? nil : keyPassphrase
        }
        Task {
            defer { isConnecting = false }
            do {
                let engine = try await RemoteEngine(connection: connection, credentials: credentials)
                _ = try await engine.list(.root)
                try store.save(credentials, for: connection.id)
                AppLog.record("\(connection.displayName): signed in again")
                signedIn()
                dismiss()
            } catch {
                AppLog.record("\(connection.displayName): sign-in didn't work: \(Diagnostics.kind(of: error))")
                problem = Tailnet.explain(error, for: connection.endpoint)
            }
        }
    }
}
