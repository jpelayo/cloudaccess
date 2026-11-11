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

/// What the app is, and its uninstall. Settings and the log are on the Settings page.
struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    let places: FilesPlaces
    let drives: OpenDrives
    /// Set once Uninstall is pressed, and the sheet shows the uninstall instead.
    @State private var uninstaller: PhoneUninstaller?

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
