// Apache 2 license - developer@infinitecontext.com

import CloudCore
import CloudDesign
import Foundation
import LocalAuthentication
import RemoteEngine
import SwiftUI
import UniformTypeIdentifiers

/// The bytes of a drives file to import, from the Import button or from AirDrop.
struct DrivesFileToImport: Identifiable {
    let id = UUID()
    let data: Data
}

enum DrivesFileAccess {
    /// Every password on this iPhone is about to leave it, so its owner proves who they are first.
    static func confirmOwner() async -> Bool {
        let context = LAContext()
        return (try? await context.evaluatePolicy(
            .deviceOwnerAuthentication,
            localizedReason: String(localized: "export your drives and their passwords"))) == true
    }

    /// Reads a chosen or received file. A copy iOS made for this app is deleted once it's read,
    /// so no second copy of the file is left on the phone.
    static func read(_ url: URL, deletingCopy: Bool) throws -> Data {
        let isScoped = url.startAccessingSecurityScopedResource()
        defer {
            if isScoped { url.stopAccessingSecurityScopedResource() }
        }
        let data = try Data(contentsOf: url)
        if deletingCopy {
            try? FileManager.default.removeItem(at: url)
        }
        return data
    }

    static func place(of entry: DrivesFile.Entry) -> String {
        switch entry.endpoint {
        case .webDAV(let url): url.absoluteString
        case .sftp(let host, let port): "sftp://\(host)\(port == 22 ? "" : ":\(port)")\(entry.rootPath)"
        case .localFolder: entry.rootPath
        }
    }

    /// Carries out the step a person chose for one drive. Like adding a drive by hand, the drive is
    /// connected and its passwords checked first. Saving then either finishes or is taken back.
    static func perform(
        _ step: DrivesFileImport.Step, for row: DrivesFileImport.Row, allowsInsecure: Bool, store: DriveStore
    ) async throws {
        let credentials = row.entry.credentials
        switch step {
        case .skip:
            return
        case .add, .addAs:
            guard var connection = DrivesFileImport.newDrive(for: row, step: step, allowsInsecure: allowsInsecure)
            else { throw ImportProblem.insecureNotAllowed }
            if let clash = DriveEdit.clash(connection, among: (try? store.connections()) ?? []) {
                throw ImportProblem.refused(clash.reason)
            }
            // The phone never creates a vault, so an encrypted drive only joins the one it came from.
            let engine = try await RemoteEngine(connection: connection, credentials: credentials)
            _ = try await engine.list(.root)
            connection.vaultID = engine.vault?.id ?? connection.vaultID
            connection.vaultRevision = engine.vault?.revision ?? connection.vaultRevision
            let saved = connection
            try await DrivesFileImport.allOrNothing([
                DrivesFileImport.Action(
                    run: { try store.save(credentials, for: saved.id) },
                    undo: { try? store.remove(id: saved.id) }),
                DrivesFileImport.Action(
                    run: { try store.save(saved) },
                    undo: { try? store.remove(id: saved.id) }),
            ])
            AppLog.record("\(saved.displayName): added from a drives file")
        case .updatePasswords, .updatePasswordsAndSettings:
            guard case .alreadyHere(let id) = row.situation,
                  let existing = try store.connections().first(where: { $0.id == id }),
                  let updated = DrivesFileImport.updatedDrive(existing, for: row, step: step)
            else { return }
            let engine = try await RemoteEngine(connection: updated, credentials: credentials)
            _ = try await engine.list(.root)
            let previous = try store.credentials(for: id)
            try await DrivesFileImport.allOrNothing([
                DrivesFileImport.Action(
                    run: { try store.save(credentials, for: id) },
                    undo: { try? store.save(previous, for: id) }),
                DrivesFileImport.Action(
                    run: { try store.save(updated) },
                    undo: { try? store.save(existing) }),
            ])
            AppLog.record("\(existing.displayName): passwords updated from a drives file")
        }
    }

    enum ImportProblem: LocalizedError {
        case insecureNotAllowed
        case refused(String)

        var errorDescription: String? {
            switch self {
            case .insecureNotAllowed:
                String(localized: "This drive uses plain http, which sends its password readably. Allow that first.")
            case .refused(let reason):
                reason
            }
        }
    }
}

/// Chooses drives and a password, then shares the file, which includes AirDrop and Save to Files.
struct ExportDrivesView: View {
    let store: DriveStore
    let drives: [Connection]

    @Environment(\.dismiss) private var dismiss
    @State private var chosen: Set<UUID>
    @State private var password = Passphrase.generate()
    @State private var shared: SharedFile?
    @State private var problem: String?

    init(store: DriveStore, drives: [Connection]) {
        self.store = store
        self.drives = drives
        _chosen = State(initialValue: Set(drives.map(\.id)))
    }

    private func included(_ connection: Connection) -> Binding<Bool> {
        Binding {
            chosen.contains(connection.id)
        } set: { isOn in
            if isOn { chosen.insert(connection.id) } else { chosen.remove(connection.id) }
        }
    }

    private func share() {
        problem = nil
        do {
            let entries = try drives.filter { chosen.contains($0.id) }.map { connection in
                DrivesFile.Entry(connection, credentials: try store.credentials(for: connection.id))
            }
            let data = try DrivesFile.seal(entries, password: password)
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent(DrivesFile.suggestedName())
            try data.write(to: file, options: [.atomic, .completeFileProtection])
            AppLog.record("Exported \(entries.count) drives to a drives file")
            shared = SharedFile(url: file)
        } catch {
            problem = error.localizedDescription
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(drives) { connection in
                        Toggle(connection.displayName, isOn: included(connection))
                    }
                } header: {
                    SectionLabel("Drives")
                }
                Section {
                    TextField("Password", text: $password)
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("New Password") { password = Passphrase.generate() }
                } header: {
                    SectionLabel("Password")
                } footer: {
                    Text("Attention: this file and its password open every drive in it. Send the password separately, never with the file.")
                }
                Section {
                    Button("Share…") { share() }
                        // A password that's too short is refused with the reason, shown below.
                        .disabled(chosen.isEmpty)
                } footer: {
                    if let problem {
                        Text(problem)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Export Drives")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $shared) { file in
                ShareSheet(file: file.url)
            }
        }
    }
}

/// Opens a drives file with its password, then lets a person choose what happens to each drive.
struct ImportDrivesView: View {
    let store: DriveStore
    let file: DrivesFileToImport
    /// Drives whose passwords changed, so their connections and Files places sign in again.
    let finished: (_ updated: Set<UUID>) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var rows: [DrivesFileImport.Row]?
    @State private var steps: [Int: DrivesFileImport.Step] = [:]
    @State private var consent: Set<Int> = []
    @State private var results: [Int: Result<Void, Error>] = [:]
    @State private var updated: Set<UUID> = []
    @State private var isWorking = false
    @State private var problem: String?

    /// The step chosen, or the one the row starts on.
    private func chosenStep(for row: DrivesFileImport.Row) -> DrivesFileImport.Step {
        steps[row.id] ?? row.startingStep
    }

    private func step(for row: DrivesFileImport.Row) -> Binding<DrivesFileImport.Step> {
        Binding { chosenStep(for: row) } set: { steps[row.id] = $0 }
    }

    private func allowed(_ row: DrivesFileImport.Row) -> Binding<Bool> {
        Binding {
            consent.contains(row.id)
        } set: { isOn in
            if isOn { consent.insert(row.id) } else { consent.remove(row.id) }
        }
    }

    private var chosenRows: [DrivesFileImport.Row] {
        (rows ?? []).filter { chosenStep(for: $0) != .skip }
    }

    private var chosenCount: Int {
        chosenRows.count
    }

    /// Every drive chosen was imported, so there's nothing left to see here.
    private var everyChosenDriveWorked: Bool {
        !chosenRows.isEmpty && chosenRows.allSatisfy { row in
            if case .success = results[row.id] { true } else { false }
        }
    }

    private func open() {
        problem = nil
        isWorking = true
        let data = file.data, password = password
        Task {
            defer { isWorking = false }
            do {
                let entries = try await Task.detached { try DrivesFile.open(data, password: password) }.value
                rows = DrivesFileImport.rows(for: entries, among: (try? store.connections()) ?? [], on: .phone)
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    /// One drive at a time, so each finishes or changes nothing before the next begins.
    private func importChosen() {
        guard let rows else { return }
        isWorking = true
        Task {
            defer { isWorking = false }
            for row in rows {
                let chosen = chosenStep(for: row)
                guard chosen != .skip, results[row.id] == nil else { continue }
                do {
                    try await DrivesFileAccess.perform(chosen, for: row, allowsInsecure: consent.contains(row.id), store: store)
                    results[row.id] = .success(())
                    if case .alreadyHere(let id) = row.situation {
                        updated.insert(id)
                    }
                } catch {
                    results[row.id] = .failure(error)
                }
            }
            // A failure stays on screen with its reason.
            if everyChosenDriveWorked {
                finished(updated)
                dismiss()
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                if let rows {
                    Section {
                        Text("Choose what happens to each drive. Nothing happens to a drive left on Skip, and no drive is ever removed.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(rows) { row in
                        Section {
                            Picker(row.entry.name, selection: step(for: row)) {
                                ForEach(row.steps, id: \.self) { step in
                                    Text(step.title).tag(step)
                                }
                            }
                            .disabled(results[row.id] != nil || isWorking)
                            if row.needsInsecureConsent, chosenStep(for: row) != .skip {
                                Toggle("Send its password over plain http", isOn: allowed(row))
                            }
                        } footer: {
                            Text(result(of: row) ?? row.note ?? DrivesFileAccess.place(of: row.entry))
                                .foregroundStyle(isFailed(row) ? .red : .secondary)
                        }
                    }
                    Section {
                        // One key, with a form for one drive and one for more in the catalog.
                        Button("Import \(chosenCount) Drives") { importChosen() }
                            .disabled(chosenCount == 0 || isWorking)
                    }
                } else {
                    Section {
                        SecureField("The file's password", text: $password)
                            .onSubmit(open)
                        Button("Open") { open() }
                            .disabled(password.isEmpty || isWorking)
                    } header: {
                        SectionLabel("Password")
                    }
                }
                if let problem {
                    Section {
                        Text(problem)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Import Drives")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        finished(updated)
                        dismiss()
                    }
                    .disabled(isWorking)
                }
            }
        }
    }

    private func result(of row: DrivesFileImport.Row) -> String? {
        switch results[row.id] {
        case .success: String(localized: "Done.")
        case .failure(let error): error.localizedDescription
        case nil: nil
        }
    }

    private func isFailed(_ row: DrivesFileImport.Row) -> Bool {
        if case .failure = results[row.id] { true } else { false }
    }
}
