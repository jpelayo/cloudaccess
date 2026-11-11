// Apache 2 license - developer@infinitecontext.com

import CloudCore
import CloudDesign
import Foundation
import SwiftUI

/// Megabytes with one decimal, as iOS's limit is written, with the decimal mark of the language
/// shown. The log keeps `MemoryReport.megabytes`, so support always reads it the same way.
// TODO(l10n): use MemoryReport's own variant for the screen if the package adds one.
private func megabytes(_ bytes: UInt64) -> String {
    (Double(bytes) / 1_048_576).formatted(.number.precision(.fractionLength(1))) + " MB"
}

/// Everything that isn't a drive: drives files, the language, the log, the Mac app and About. The
/// sheets for drives files, the Mac app and About belong to the drives list, which also opens a
/// drives file sent with AirDrop.
struct PhoneSettingsView: View {
    let canExport: Bool
    @Binding var drivesFileProblem: String?
    let exportDrives: () -> Void
    let importDrives: () -> Void
    let showCloudAccess: () -> Void
    let showAbout: () -> Void

    @State private var language = AppLanguage.chosen()
    /// iOS reads the language at launch, and an app can't restart itself.
    @State private var languageChanged = false
    @State private var sharedLog: SharedFile?

    private var languageChoice: Binding<AppLanguage> {
        Binding {
            language
        } set: { chosen in
            AppLanguage.choose(chosen)
            language = chosen
            languageChanged = true
        }
    }

    var body: some View {
        List {
            Section {
                Button(action: exportDrives) {
                    Label("Export Drives…", systemImage: "square.and.arrow.up")
                        .wholeRow()
                }
                .disabled(!canExport)
                Button(action: importDrives) {
                    Label("Import Drives…", systemImage: "square.and.arrow.down")
                        .wholeRow()
                }
            } header: {
                SectionLabel("Drives file")
            } footer: {
                if let drivesFileProblem {
                    Text(drivesFileProblem)
                        .foregroundStyle(.red)
                } else {
                    Text("Moves drives and their passwords to another iPhone or Mac, in one encrypted file.")
                }
            }
            Section {
                Picker("Language", selection: languageChoice) {
                    ForEach(AppLanguage.allCases, id: \.self) { choice in
                        Text(verbatim: choice.title).tag(choice)
                    }
                }
            } header: {
                SectionLabel("Language")
            } footer: {
                if languageChanged {
                    Text("Close and reopen CloudWanderer to apply it.")
                } else {
                    Text("System follows your iPhone's language.")
                }
            }
            Section {
                NavigationLink("Show Log") {
                    LogView()
                }
                Button("Share Log") {
                    Task { await shareLog() }
                }
            } header: {
                SectionLabel("Log")
            } footer: {
                Text("What happened to your drives, without file names or passwords. It stays on this iPhone unless you share it.")
            }
            if let report = PhoneDrives.memoryReport {
                Section {
                    // The event is the extension's own word, kept as it recorded it, and the
                    // values are built as strings so only the labels are looked up.
                    KeyValueRow("After", report.event + ", " + report.date.formatted(date: .omitted, time: .standard))
                    KeyValueRow("Then", megabytes(report.now))
                    KeyValueRow("Peak that run", megabytes(report.peak))
                    KeyValueRow("Highest seen", megabytes(report.highest))
                    if let limit = report.limit {
                        KeyValueRow("Limit", megabytes(limit))
                    }
                    if let drives = report.drives, let threads = report.threads {
                        KeyValueRow("Drives, threads", drives.formatted() + ", " + threads.formatted())
                    }
                } header: {
                    SectionLabel("Files extension memory")
                }
            }
            Section {
                Button(action: showCloudAccess) {
                    Label("CloudAccess for Mac", systemImage: "laptopcomputer")
                        .wholeRow()
                }
                Button(action: showAbout) {
                    Label("About", systemImage: "info.circle")
                        .wholeRow()
                }
            }
        }
        .navigationTitle("Settings")
        .sheet(item: $sharedLog) { shared in
            ShareSheet(file: shared.url)
        }
    }

    /// Writes the log to a file named for today, redacted on the way out, and offers it to share.
    /// Reading and redacting up to a few megabytes happens off the main thread.
    private func shareLog() async {
        let store = PhoneDrives.store
        var lines = [AppLog.versionLine]
        for connection in (try? store.connections()) ?? [] {
            lines.append(ConnectionSummary.line(for: connection, status: nil))
        }
        if let report = PhoneDrives.memoryReport {
            lines.append("Files extension memory: \(report.summary)")
        }
        let header = lines.joined(separator: "\n")
        let diagnostics = store.diagnostics
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("CloudWanderer log \(Date().ISO8601Format().prefix(10)).txt")
        let written = await Task.detached(priority: .userInitiated) {
            Result { try diagnostics.exportedText(header: header).write(to: file, atomically: true, encoding: .utf8) }
        }.value
        switch written {
        case .success:
            sharedLog = SharedFile(url: file)
        case .failure(let error):
            AppLog.record("The log couldn't be written for sharing: \(Diagnostics.kind(of: error))")
        }
    }
}
