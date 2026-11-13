// Apache 2 license - developer@infinitecontext.com

import AppKit
import CloudCore
import CloudDesign
import LocalAuthentication
import SwiftUI
import UniformTypeIdentifiers

/// A drives file's bytes, for the save panel.
struct DrivesFileDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.drivesFile]
    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// The bytes of a drives file a person chose to import.
struct DrivesFileToImport: Identifiable {
    let id = UUID()
    let data: Data
}

enum DrivesFileAccess {
    /// Every password on this Mac is about to leave it, so the person at the keyboard proves
    /// they're the Mac's owner first.
    static func confirmOwner() async -> Bool {
        let context = LAContext()
        // macOS puts this after the app's name: "CloudAccess is trying to export…".
        let reason = String(localized: "export your drives and their passwords")
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) == true
    }

    /// Reads a file the open panel granted, without keeping access to it.
    static func read(_ url: URL) throws -> Data {
        let isScoped = url.startAccessingSecurityScopedResource()
        defer {
            if isScoped { url.stopAccessingSecurityScopedResource() }
        }
        return try Data(contentsOf: url)
    }
}

/// Chooses drives and a password, then saves the file or sends it with AirDrop.
struct ExportDrivesView: View {
    @Environment(Drives.self) private var drives
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: Set<UUID>
    @State private var password = Passphrase.generate()
    @State private var document: DrivesFileDocument?
    @State private var isSaving = false
    @State private var problem: String?
    @State private var message: String?

    init(drives: [Connection]) {
        _chosen = State(initialValue: Set(drives.map(\.id)))
    }

    private func included(_ connection: Connection) -> Binding<Bool> {
        Binding {
            chosen.contains(connection.id)
        } set: { isOn in
            if isOn { chosen.insert(connection.id) } else { chosen.remove(connection.id) }
        }
    }

    private func sealed() -> Data? {
        problem = nil
        message = nil
        do {
            return try drives.drivesFile(of: chosen, password: password)
        } catch {
            problem = error.localizedDescription
            return nil
        }
    }

    /// AirDrop needs a file, so the sealed bytes go to a private temporary folder first.
    private func sendWithAirDrop() {
        guard let data = sealed() else { return }
        do {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent(DrivesFile.suggestedName())
            try data.write(to: file, options: .atomic)
            guard let airDrop = NSSharingService(named: .sendViaAirDrop), airDrop.canPerform(withItems: [file]) else {
                problem = String(localized: "AirDrop isn't available. Save the file and send it another way.")
                return
            }
            airDrop.perform(withItems: [file])
        } catch {
            problem = error.localizedDescription
        }
    }

    var body: some View {
        SheetPage {
            Text("Export Drives")
                .font(.headline)
        } content: {
            VStack(alignment: .leading, spacing: Design.labelGap) {
                SectionLabel("Drives")
                BoundedList(rows: drives.exportable.count, rowHeight: RowHeight.single, visibleRows: 5) {
                    ForEach(drives.exportable) { connection in
                        ListRow(height: RowHeight.single) {
                            Text(connection.displayName)
                        } controls: {
                            RowSwitch(label: "Include \(connection.displayName)", isOn: included(connection))
                        }
                    }
                }
            }
            CardSection("Password") {
                SettingRow("Password for the file") {
                    TextField("Password", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                        .frame(width: Pane.fieldColumn)
                }
                SettingRow("A new strong password") {
                    Button("New Password") { password = Passphrase.generate() }
                        .buttonStyle(.pill)
                }
            }
            Text("Attention: this file and its password open every drive in it. Send the password separately, never with the file, and type it on the other device.")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            CardSection("Export") {
                SettingRow("Save it as a file") {
                    Button("Save…") {
                        if let data = sealed() {
                            document = DrivesFileDocument(data: data)
                            isSaving = true
                        }
                    }
                    .buttonStyle(.pill)
                }
                SettingRow("Send it to a nearby iPhone or Mac") {
                    Button("Send with AirDrop…") { sendWithAirDrop() }
                        .buttonStyle(.pill)
                }
            }
            // A password that's too short is refused with the reason when pressed, not by a
            // button that's greyed out with nothing to say why.
            .disabled(chosen.isEmpty)
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                if let message {
                    Text(message)
                        .foregroundStyle(.secondary)
                }
                if let problem {
                    Text(problem)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Spacer()
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .fileExporter(
            isPresented: $isSaving, document: document, contentType: .drivesFile,
            defaultFilename: DrivesFile.suggestedName()
        ) { result in
            switch result {
            case .success: message = String(localized: "Saved.")
            case .failure(let error): problem = error.localizedDescription
            }
        }
    }
}

/// Opens a drives file with its password, then lets a person choose what happens to each drive.
struct ImportDrivesView: View {
    @Environment(Drives.self) private var drives
    @Environment(\.dismiss) private var dismiss
    let file: DrivesFileToImport

    @State private var password = ""
    @State private var rows: [DrivesFileImport.Row]?
    @State private var steps: [Int: DrivesFileImport.Step] = [:]
    @State private var consent: Set<Int> = []
    @State private var results: [Int: Result<Void, Error>] = [:]
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
                rows = DrivesFileImport.rows(for: entries, among: drives.connections, on: .mac)
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
                    try await drives.importStep(chosen, for: row, allowsInsecure: consent.contains(row.id))
                    results[row.id] = .success(())
                } catch {
                    results[row.id] = .failure(error)
                }
            }
            // A failure stays on screen with its reason.
            if everyChosenDriveWorked {
                dismiss()
            }
        }
    }

    var body: some View {
        SheetPage {
            Text("Import Drives")
                .font(.headline)
        } content: {
            if let rows {
                review(rows)
            } else {
                CardSection("Password") {
                    SettingRow("The file's password") {
                        SecureField("Password", text: $password)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: Pane.fieldColumn)
                            .onSubmit(open)
                    }
                    SettingRow("Read the drives in it") {
                        Button("Open") { open() }
                            .buttonStyle(.pill)
                            .disabled(password.isEmpty || isWorking)
                    }
                }
            }
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                if let problem {
                    Text(problem)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Spacer()
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .disabled(isWorking)
                }
            }
        }
    }

    @ViewBuilder
    private func review(_ rows: [DrivesFileImport.Row]) -> some View {
        Text("Choose what happens to each drive. Nothing happens to a drive left on Skip, and no drive is ever removed.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        // Each drive takes the height it needs, the http question included. The sheet scrolls,
        // so a file with many drives doesn't need a list of its own.
        SettingsSection {
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: 6) {
                    SettingRow(
                        Text(verbatim: row.entry.name),
                        caption: Text(verbatim: result(of: row) ?? row.note ?? row.entry.shownLocation),
                        captionColor: isFailed(row) ? .red : .secondary
                    ) {
                        Picker("What to do with \(row.entry.name)", selection: step(for: row)) {
                            ForEach(row.steps, id: \.self) { step in
                                Text(step.title).tag(step)
                            }
                        }
                        .frame(width: Pane.valueColumn)
                        .disabled(results[row.id] != nil || isWorking)
                    }
                    if row.needsInsecureConsent, chosenStep(for: row) != .skip {
                        SettingRow("Send its password over plain http") {
                            RowSwitch(label: "Allow plain http for \(row.entry.name)", isOn: allowed(row))
                        }
                    }
                }
            }
        }
        SettingRow("\(chosenCount) drives chosen") {
            Button("Import") { importChosen() }
                .buttonStyle(.pill)
                .disabled(chosenCount == 0 || isWorking)
        }
        if results.values.contains(where: { if case .success = $0 { true } else { false } }) {
            Text("A new drive appears in Finder once it's switched on in System Settings, as with any drive you add.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
