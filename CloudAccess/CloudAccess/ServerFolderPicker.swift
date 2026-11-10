// Apache 2 license - developer@infinitecontext.com

import CloudCore
import CloudDesign
import RemoteEngine
import SwiftUI

/// A look at a server's folders before a drive exists. The engine closes when this goes.
struct FolderBrowsing: Identifiable {
    let id = UUID()
    /// What the folders here are relative to.
    let start: ConnectionForm
    let engine: RemoteEngine
}

/// Chooses where a new drive goes, from the folders on its server. Looking writes nothing, and
/// New Folder is the only thing here that changes the server.
struct ServerFolderPicker: View {
    @Environment(\.dismiss) private var dismiss

    let engine: RemoteEngine
    let chosen: (RemotePath) -> Void

    @State private var folder = RemotePath.root
    @State private var folders: [String] = []
    @State private var isLoading = true
    @State private var newName = ""
    @State private var isCreating = false
    @State private var problem: String?

    private var rows: Int {
        folders.count + (folder.isRoot ? 0 : 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.sectionGap) {
            VStack(alignment: .leading, spacing: Design.labelGap) {
                SectionLabel("Folders on the server")
                Text(folder.isRoot ? String(localized: "Top folder") : folder.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                BoundedList(rows: rows, rowHeight: RowHeight.single, visibleRows: 8) {
                    if let parent = folder.parent {
                        folderRow(String(localized: "Up one level"), symbol: "arrow.up") { folder = parent }
                    }
                    ForEach(folders, id: \.self) { name in
                        folderRow(name, symbol: "folder") {
                            if let inside = folder.appending(name) {
                                folder = inside
                            }
                        }
                    }
                    if folders.isEmpty {
                        Text(isLoading ? "Loading…" : "No folders here.")
                            .foregroundStyle(.secondary)
                            .frame(height: RowHeight.single)
                    }
                }
            }
            CardSection("New folder") {
                FieldRow(label: "Name", text: $newName)
                SettingRow("Make it inside this folder") {
                    Button("Create") { create() }
                        .buttonStyle(.pill)
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty || isCreating)
                }
            }
            if let problem {
                Text(problem)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .task(id: folder) { await load() }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Use This Folder") {
                    chosen(folder)
                    dismiss()
                }
            }
        }
    }

    /// A folder's name, or words already in the language shown, as they are.
    private func folderRow(_ name: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(verbatim: name)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(height: RowHeight.single)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func load() async {
        isLoading = true
        problem = nil
        defer { isLoading = false }
        do {
            let items = try await engine.list(folder)
            folders = items.filter { $0.kind == .directory }.map(\.path.name)
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        } catch {
            folders = []
            let reason = error.localizedDescription
            problem = String(localized: "This folder can't be read: \(reason)")
        }
    }

    private func create() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard let path = folder.appending(name), !RemotePath.isReservedName(name) else {
            problem = String(localized: "That name can't be used for a folder.")
            return
        }
        isCreating = true
        problem = nil
        Task {
            defer { isCreating = false }
            do {
                try await engine.createDirectory(path)
                newName = ""
                folder = path
            } catch {
                let reason = error.localizedDescription
                problem = String(localized: "That folder couldn't be made: \(reason)")
            }
        }
    }
}
