// Apache 2 license - developer@infinitecontext.com

import CloudCore
import CloudDesign
import SwiftUI

/// Where a drive is: the protocol, the server, the account and the folder. Adding and editing
/// share these, built on the same `ConnectionForm` as the Mac's, so an iPhone reaches every server
/// the Mac does, SFTP included, by the same rules.
struct DriveFormFields: View {
    @Binding var form: ConnectionForm
    /// A person's say-so to send the password readably over plain http, when it's asked here.
    let insecureConsent: Binding<Bool>?
    /// More to say under the server's fields, already in the language shown.
    let serverNote: String?
    let canBrowse: Bool
    let browse: () -> Void

    var body: some View {
        Section {
            Picker("Protocol", selection: $form.kind) {
                ForEach(ConnectionForm.Kind.allCases, id: \.self) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            TextField("Host", text: $form.host, prompt: Text(verbatim: "example.com"))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .textContentType(.URL)
                // A whole address pasted here is read into the fields it belongs in, straight away.
                // Typing goes on undisturbed: a port typed after a colon stays where it's typed.
                .onChange(of: form.host) { old, new in
                    if new.count > old.count + 1 || new.contains("://") {
                        form.tidyHost()
                    }
                }
                .onSubmit { form.tidyHost() }
            TextField("Port", text: $form.port, prompt: Text("Usual (\(form.kind.defaultPort))"))
                .keyboardType(.numberPad)
            TextField("Username", text: $form.username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textContentType(.username)
            if form.tidied.kind == .http, let insecureConsent {
                Toggle("Send my password unencrypted over http", isOn: insecureConsent)
            }
        } header: {
            SectionLabel("Server")
        } footer: {
            if let serverNote {
                Text(verbatim: serverNote)
            }
        }
        Section {
            TextField("Folder", text: $form.path, prompt: Text(form.kind == .sftp ? LocalizedStringKey("Home folder") : LocalizedStringKey("Top folder")))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Browse…", systemImage: "folder") { browse() }
                .disabled(!canBrowse)
        } header: {
            SectionLabel("Folder")
        } footer: {
            // On SFTP, Documents and /Documents are two places, so it says which this is.
            if let problem = form.tidied.folderProblem {
                Text(verbatim: problem)
                    .foregroundStyle(.red)
            } else if let place = form.tidied.shownPlace {
                Text(verbatim: place)
            }
        }
    }
}
