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
    /// The folder already in the form, relative to `start`, if it's inside it.
    let typed: RemotePath?
    /// Whether + may make a folder. A read-only drive writes nothing, not even from here.
    var canMake = true
}

/// Chooses where a new drive goes, from the folders on its server. A folder's name goes inside
/// it, and its checkmark chooses it. Looking writes nothing; + is the only thing here that changes
/// the server.
struct ServerFolderPicker: View {
    @Environment(\.dismiss) private var dismiss

    let session: FolderBrowsing
    let chosen: (RemotePath) -> Void

    @State private var tree: FolderTree
    @State private var isNaming = false
    @State private var newName = ""
    @FocusState private var isNameFocused: Bool

    init(session: FolderBrowsing, chosen: @escaping (RemotePath) -> Void) {
        self.session = session
        self.chosen = chosen
        let engine = session.engine
        let list: FolderTree.Lister = { try await engine.list($0) }
        let make: FolderTree.Maker = { try await engine.createDirectory($0) }
        _tree = State(initialValue: FolderTree(chosen: session.typed, list: list, make: session.canMake ? make : nil))
    }

    private var isSFTP: Bool {
        session.start.kind == .sftp
    }

    /// The top, named for what it is on this protocol.
    private var topName: String {
        isSFTP ? String(localized: "Home folder") : String(localized: "Top folder")
    }

    /// One line for each folder, and one each for the top, the new name, and a message.
    private var rows: Int {
        var count = tree.folders.count
        if tree.folder.isRoot { count += 1 }
        if isNaming { count += 1 }
        if tree.isLoading || tree.problem != nil || tree.folders.isEmpty { count += 1 }
        return count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.sectionGap) {
            header
            BoundedList(rows: rows, rowHeight: RowHeight.single, visibleRows: 10) {
                if isNaming {
                    nameRow
                }
                if tree.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, minHeight: RowHeight.single)
                } else {
                    if tree.folder.isRoot {
                        row(topName, symbol: isSFTP ? "house" : "externaldrive", path: .root, opens: false)
                    }
                    ForEach(tree.folders, id: \.self) { name in
                        if let path = tree.folder.appending(name) {
                            row(name, symbol: "folder", path: path, opens: true)
                        }
                    }
                    if let problem = tree.problem {
                        Text(verbatim: problem)
                            .foregroundStyle(.red)
                            .lineLimit(2)
                            .frame(minHeight: RowHeight.single)
                    } else if tree.folders.isEmpty {
                        Text("No folders here.")
                            .foregroundStyle(.secondary)
                            .frame(height: RowHeight.single)
                    }
                }
            }
            // The chosen folder's place, shown only once one is chosen.
            if let chosenPlace {
                Text(verbatim: chosenPlace)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.head)
            }
        }
        .padding(16)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .task { await tree.load() }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Use This Folder") {
                    if let folder = tree.chosen {
                        chosen(folder)
                        dismiss()
                    }
                }
                .disabled(tree.chosen == nil)
            }
        }
    }

    /// Back on the left, where the list is in the middle, and + on the right.
    private var header: some View {
        HStack(spacing: 8) {
            Button {
                isNaming = false
                Task { await tree.back() }
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.icon)
            .disabled(tree.folder.isRoot)
            .help("Back")
            .accessibilityLabel(Text("Back"))
            Text(verbatim: tree.folder.isRoot ? topName : tree.folder.name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if session.canMake {
                Button {
                    isNaming = true
                    isNameFocused = true
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.icon)
                .disabled(tree.isLoading)
                .help("New Folder")
                .accessibilityLabel(Text("New Folder"))
            }
        }
    }

    /// A new folder's name. Return makes it here and chooses it, and Escape leaves it.
    private var nameRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.badge.plus")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Folder name", text: $newName)
                .textFieldStyle(.plain)
                .focused($isNameFocused)
                .onSubmit {
                    Task {
                        if await tree.create(newName) {
                            newName = ""
                            isNaming = false
                        }
                    }
                }
                .onExitCommand {
                    newName = ""
                    isNaming = false
                }
        }
        .frame(height: RowHeight.single)
    }

    /// A folder: its name goes inside it, and its checkmark chooses it.
    private func row(_ name: String, symbol: String, path: RemotePath, opens: Bool) -> some View {
        let isChosen = tree.chosen == path
        return HStack(spacing: 8) {
            Button {
                if opens {
                    isNaming = false
                    Task { await tree.open(name) }
                } else {
                    tree.choose(path)
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: symbol)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(verbatim: name)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if opens {
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button {
                tree.choose(path)
            } label: {
                Image(systemName: isChosen ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isChosen ? Color.accentColor : .secondary)
                    .font(.system(size: 15))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(isChosen ? LocalizedStringKey("Chosen") : LocalizedStringKey("Choose")))
        }
        .frame(height: RowHeight.single)
    }

    /// Where the chosen folder is, as the drive will use it.
    private var chosenPlace: String? {
        guard let folder = tree.chosen else { return nil }
        var form = session.start
        form.path = session.start.folderField(for: folder)
        if let place = form.shownPlace {
            return place
        }
        return form.path.isEmpty ? String(localized: "Top folder") : form.path
    }
}
