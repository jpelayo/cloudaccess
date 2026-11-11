// Apache 2 license - developer@infinitecontext.com

import CloudCore
import CloudDesign
import Foundation
import SwiftUI

/// The app's version, as the About screen shows it.
private var version: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
}

/// A name, so it reads the same in every language and is never looked up.
private let developer = "InfiniteContext.com"

/// Megabytes with one decimal, as iOS's limit is written, with the decimal mark of the language
/// shown. The log keeps `MemoryReport.megabytes`, so support always reads it the same way.
// TODO(l10n): use MemoryReport's own variant for the screen if the package adds one.
private func megabytes(_ bytes: UInt64) -> String {
    (Double(bytes) / 1_048_576).formatted(.number.precision(.fractionLength(1))) + " MB"
}

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    let places: FilesPlaces
    let drives: OpenDrives
    @State private var sharedLog: SharedFile?
    @State private var language = AppLanguage.chosen()
    /// iOS reads the language at launch, and an app can't restart itself.
    @State private var languageChanged = false
    /// Set once Uninstall is pressed, and the sheet shows the uninstall instead.
    @State private var uninstaller: PhoneUninstaller?

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
        NavigationStack {
            Group {
                if let uninstaller {
                    UninstallView(uninstaller: uninstaller) {
                        withAnimation(.easeInOut(duration: 0.2)) { self.uninstaller = nil }
                    }
                } else {
                    about
                }
            }
            .transition(.opacity)
            .toolbar {
                if !(uninstaller?.isRunning ?? false) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $sharedLog) { shared in
                ShareSheet(file: shared.url)
            }
        }
        // Nothing may leave the screen while a drive is being removed.
        .interactiveDismissDisabled(uninstaller?.isRunning ?? false)
    }

    private var about: some View {
        List {
            Section {
                KeyValueRow("Version", version)
                KeyValueRow("Licence", String(localized: "Apache 2 licensed software"))
                KeyValueRow("Developed by", developer)
            } header: {
                SectionLabel("CloudWanderer")
            }
            Section {
                Text("Browse your own WebDAV and SFTP servers, and download and export files from them. Nothing is sent anywhere else.")
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
                Button("Uninstall CloudWanderer…", role: .destructive) {
                    let made = PhoneUninstaller(places: places, drives: drives)
                    withAnimation(.easeInOut(duration: 0.2)) { uninstaller = made }
                    Task { await made.review() }
                }
            } header: {
                SectionLabel("Uninstall")
            } footer: {
                Text("Removes your drives and their passwords from this iPhone. Files on your servers are not changed.")
            }
        }
        .navigationTitle("About CloudWanderer")
        .navigationBarTitleDisplayMode(.inline)
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

/// The latest lines, newest first, in a list of their own.
struct LogView: View {
    @State private var lines: [String]?

    var body: some View {
        List {
            ForEach(Array((lines ?? []).reversed().enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
        }
        .overlay {
            if lines == nil {
                ProgressView()
            } else if lines?.isEmpty == true {
                ContentUnavailableView("Nothing Recorded Yet", systemImage: "doc.text")
            }
        }
        .navigationTitle("Log")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        let diagnostics = PhoneDrives.store.diagnostics
        lines = await Task.detached(priority: .userInitiated) {
            diagnostics.recentLines(limit: 500)
        }.value
    }
}

/// A file to hand to the share sheet, once it's written.
struct SharedFile: Identifiable {
    let url: URL
    var id: URL { url }
}

struct CloudAccessView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("CloudAccess puts these same drives in Finder on your Mac, where you can also change and add files.")
                } header: {
                    SectionLabel("On your Mac")
                }
                Section {
                    Text("To add a drive here, open CloudAccess, then choose the QR icon beside the drive.")
                } header: {
                    SectionLabel("Adding a drive")
                }
            }
            .navigationTitle("CloudAccess for Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("Done") { dismiss() }
            }
        }
    }
}
