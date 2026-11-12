// Apache 2 license - developer@infinitecontext.com

import Foundation
import Observation

/// Looking through a server's folders to choose one. Pressing a folder's name goes inside it, and
/// its checkmark chooses it; the folder a person is looking at and the one chosen are separate, so
/// choosing never means navigating. Both apps' pickers use it.
@MainActor @Observable
public final class FolderTree {
    public typealias Lister = @Sendable (RemotePath) async throws -> [RemoteItem]
    public typealias Maker = @Sendable (RemotePath) async throws -> Void

    /// The folder being looked at.
    public private(set) var folder: RemotePath
    /// The folders inside it, by name, in the order a person reads them.
    public private(set) var folders: [String] = []
    /// The folder chosen, which may be anywhere. Nil until one is.
    public private(set) var chosen: RemotePath?
    public private(set) var isLoading = false
    /// Why the folder couldn't be read or made, in the language shown.
    public private(set) var problem: String?

    private let list: Lister
    private let make: Maker?
    /// Only the newest listing is shown, if a person moves on before an older one answers.
    private var listing = 0

    /// - Parameters:
    ///   - chosen: The folder already chosen. Looking starts in the folder that holds it, so it
    ///     shows with its checkmark.
    ///   - make: Makes a folder. Nil where nothing may be written, as on the iPhone.
    ///   - start: Where to look, for a picker that pushes one screen per folder.
    public init(at start: RemotePath? = nil, chosen: RemotePath? = nil, list: @escaping Lister, make: Maker? = nil) {
        self.chosen = chosen
        folder = start ?? chosen?.parent ?? .root
        self.list = list
        self.make = make
    }

    public var canCreate: Bool {
        make != nil
    }

    /// Reads the folder being looked at. Its hidden folders, such as `.cloudmount`, aren't shown:
    /// a drive can't be one.
    public func load() async {
        listing += 1
        let mine = listing
        isLoading = true
        problem = nil
        do {
            let items = try await list(folder)
            guard mine == listing else { return }
            folders = items
                .filter { $0.kind == .directory && !$0.path.name.hasPrefix(".") }
                .map(\.path.name)
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        } catch {
            guard mine == listing else { return }
            folders = []
            problem = Words.format("This folder can't be read: %@", error.localizedDescription)
        }
        isLoading = false
    }

    /// Goes inside a folder shown here.
    public func open(_ name: String) async {
        guard let inside = folder.appending(name) else { return }
        folder = inside
        folders = []
        await load()
    }

    /// Goes up one folder. Nothing happens at the top.
    public func back() async {
        guard let parent = folder.parent else { return }
        folder = parent
        folders = []
        await load()
    }

    /// Chooses a folder inside the one being looked at, or the top itself.
    public func choose(_ path: RemotePath) {
        chosen = path
    }

    /// Makes a folder inside the one being looked at, and chooses it.
    /// - Returns: Whether it was made.
    @discardableResult
    public func create(_ typed: String) async -> Bool {
        let name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let make, RemotePath.isValidName(name), !RemotePath.isReservedName(name),
              let path = folder.appending(name)
        else {
            problem = Words.text("That name can't be used for a folder.")
            return false
        }
        do {
            try await make(path)
        } catch {
            problem = Words.format("That folder couldn't be made: %@", error.localizedDescription)
            return false
        }
        chosen = path
        await load()
        return true
    }
}
