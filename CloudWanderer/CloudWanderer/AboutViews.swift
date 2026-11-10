// Apache 2 license - developer@infinitecontext.com

import CloudCore
import CloudDesign
import SwiftUI

/// The app's version, as the About screen shows it.
private var version: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
}

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var sharedLog: SharedFile?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    KeyValueRow("Version", version)
                    KeyValueRow("Licence", "Apache 2 licensed software")
                    KeyValueRow("Developed by", "InfiniteContext.com")
                } header: {
                    SectionLabel("CloudWanderer")
                }
                Section {
                    Text("Browse your own WebDAV and SFTP servers, and download and export files from them. Nothing is sent anywhere else.")
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
                        KeyValueRow("After", "\(report.event), \(report.date.formatted(date: .omitted, time: .standard))")
                        KeyValueRow("Then", MemoryReport.megabytes(report.now))
                        KeyValueRow("Peak that run", MemoryReport.megabytes(report.peak))
                        KeyValueRow("Highest seen", MemoryReport.megabytes(report.highest))
                        if let limit = report.limit {
                            KeyValueRow("Limit", MemoryReport.megabytes(limit))
                        }
                        if let drives = report.drives, let threads = report.threads {
                            KeyValueRow("Drives, threads", "\(drives), \(threads)")
                        }
                    } header: {
                        SectionLabel("Files extension memory")
                    }
                }
            }
            .navigationTitle("About CloudWanderer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("Done") { dismiss() }
            }
            .sheet(item: $sharedLog) { shared in
                ShareSheet(file: shared.url)
            }
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
