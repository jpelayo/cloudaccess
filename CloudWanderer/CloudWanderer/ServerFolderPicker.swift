// Apache 2 license - developer@infinitecontext.com

import CloudCore
import CloudDesign
import RemoteEngine
import SwiftUI

/// A look at a server's folders before a drive exists, or before it moves. The engine closes when
/// this goes.
struct FolderBrowsing: Identifiable {
    let id = UUID()
    /// What the folders here are relative to.
    let start: ConnectionForm
    let engine: RemoteEngine
    /// The folder already in the form, relative to `start`, if it's inside it.
    let typed: RemotePath?
}

/// Chooses a drive's folder on its server, as the Mac does: a folder's name opens it, and its
/// checkmark chooses it. The iPhone writes nothing to a server, so there's no new folder here.
struct ServerFolderPicker: View {
    @Environment(\.dismiss) private var dismiss

    let session: FolderBrowsing
    let chosen: (RemotePath) -> Void

    @State private var choice: RemotePath?
    @State private var trail: [RemotePath]

    init(session: FolderBrowsing, chosen: @escaping (RemotePath) -> Void) {
        self.session = session
        self.chosen = chosen
        _choice = State(initialValue: session.typed)
        // Opens where the chosen folder is, so it shows with its checkmark.
        var folders: [RemotePath] = []
        var folder = session.typed?.parent
        while let inside = folder, !inside.isRoot {
            folders.insert(inside, at: 0)
            folder = inside.parent
        }
        _trail = State(initialValue: folders)
    }

    private var isSFTP: Bool {
        session.start.kind == .sftp
    }

    var body: some View {
        NavigationStack(path: $trail) {
            FolderLevel(folder: .root, engine: session.engine, isSFTP: isSFTP, choice: $choice)
                .navigationDestination(for: RemotePath.self) { folder in
                    FolderLevel(folder: folder, engine: session.engine, isSFTP: isSFTP, choice: $choice)
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 8) {
                if let chosenPlace {
                    Text(verbatim: chosenPlace)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.head)
                }
                Button {
                    if let choice {
                        chosen(choice)
                        dismiss()
                    }
                } label: {
                    Text("Use This Folder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(choice == nil)
            }
            .padding()
            .background(.bar)
        }
    }

    /// Where the chosen folder is, as the drive will use it.
    private var chosenPlace: String? {
        guard let folder = choice else { return nil }
        var form = session.start
        form.path = session.start.folderField(for: folder)
        if let place = form.shownPlace {
            return place
        }
        return form.path.isEmpty ? String(localized: "Top folder") : form.path
    }
}

/// One folder's folders, on a screen of its own.
private struct FolderLevel: View {
    let folder: RemotePath
    let engine: RemoteEngine
    let isSFTP: Bool
    @Binding var choice: RemotePath?

    @State private var tree: FolderTree

    init(folder: RemotePath, engine: RemoteEngine, isSFTP: Bool, choice: Binding<RemotePath?>) {
        self.folder = folder
        self.engine = engine
        self.isSFTP = isSFTP
        _choice = choice
        _tree = State(initialValue: FolderTree(at: folder, list: { try await engine.list($0) }))
    }

    private var topName: String {
        isSFTP ? String(localized: "Home folder") : String(localized: "Top folder")
    }

    var body: some View {
        List {
            if folder.isRoot {
                row(topName, symbol: isSFTP ? "house" : "externaldrive", path: .root, opens: false)
            }
            if tree.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity)
            } else {
                ForEach(tree.folders, id: \.self) { name in
                    if let path = folder.appending(name) {
                        row(name, symbol: "folder", path: path, opens: true)
                    }
                }
                if let problem = tree.problem {
                    Text(verbatim: problem)
                        .foregroundStyle(.red)
                } else if tree.folders.isEmpty {
                    Text("No folders here.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(folder.isRoot ? topName : folder.name)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await tree.load() }
        .task { await tree.load() }
    }

    /// A folder: its name opens it, and its checkmark chooses it.
    @ViewBuilder
    private func row(_ name: String, symbol: String, path: RemotePath, opens: Bool) -> some View {
        let isChosen = choice == path
        HStack {
            if opens {
                NavigationLink(value: path) {
                    Label { Text(verbatim: name) } icon: { Image(systemName: symbol) }
                }
            } else {
                Label { Text(verbatim: name) } icon: { Image(systemName: symbol) }
            }
            Button {
                choice = path
            } label: {
                Image(systemName: isChosen ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isChosen ? Color.accentColor : .secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text(isChosen ? LocalizedStringKey("Chosen") : LocalizedStringKey("Choose")))
        }
    }
}
