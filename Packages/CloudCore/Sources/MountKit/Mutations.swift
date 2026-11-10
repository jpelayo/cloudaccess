// Apache 2 license - developer@infinitecontext.com

import CloudCore
import Foundation
import SyncCore

/// Every decision about changing a drive. The File Provider extension is a thin shell over
/// this, so these rules can be tested without macOS, with a poll landing between any two steps.
///
/// Each method is safe to repeat. macOS replays a change it never got an answer for, and a
/// replay finds its own earlier work on the server and adopts it.
public struct Mutations: Sendable {
    /// What happened to a change, for telling macOS.
    public struct Outcome: Sendable, Equatable {
        public var item: SyncItem
        /// A peer's version kept the name, so macOS must fetch it.
        public var shouldFetchContent = false
        /// Other items changed too, such as a new conflict copy, so macOS should be told.
        public var changedOtherItems = false

        public init(item: SyncItem, shouldFetchContent: Bool = false, changedOtherItems: Bool = false) {
            self.item = item
            self.shouldFetchContent = shouldFetchContent
            self.changedOtherItems = changedOtherItems
        }
    }

    private let backend: any RemoteBackend
    private let store: SyncStore
    private let syncer: Syncer
    /// Read each time, because it can change while the extension is running.
    private let isReadOnly: @Sendable () -> Bool
    private let clock: @Sendable () -> Date
    /// Hears why a file was saved without its details, for the log. The save itself stands.
    private let onDetailsMissed: @Sendable (String) -> Void

    public init(
        backend: any RemoteBackend,
        store: SyncStore,
        syncer: Syncer,
        isReadOnly: @escaping @Sendable () -> Bool = { false },
        clock: @escaping @Sendable () -> Date = { Date() },
        onDetailsMissed: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.onDetailsMissed = onDetailsMissed
        self.backend = backend
        self.store = store
        self.syncer = syncer
        self.isReadOnly = isReadOnly
        self.clock = clock
    }

    /// Keeps the panel's list of failed files, and their badges, up to date. Connection problems
    /// are shown on the drive, not on each file.
    private func recording<Result>(
        id: String, name: String, _ body: () async throws -> Result
    ) async throws -> Result {
        do {
            let result = try await body()
            try? store.clearFailure(id: id, now: clock())
            return result
        } catch {
            Self.note(failure: error, id: id, name: name, store: store, now: clock())
            throw error
        }
    }

    /// Whether a change may go ahead. A new name is a person dealing with a stopped file, so it
    /// releases it. The same name isn't, because macOS can deliver a rename more than once. A file
    /// that never reached the server needs no help, because a new name makes it a new file.
    public static func checkMayTry(id: String, newName: String?, store: SyncStore) throws {
        if let newName, try store.attempt(id: id)?.name != serverName(newName, of: id, store: store) {
            try? store.clearFailure(id: id)
        }
        try store.checkNotHeld(id: id)
    }

    /// The name a change asks for, as the server has to hold it.
    private static func serverName(_ name: String, of id: String, store: SyncStore) throws -> String {
        guard let item = try store.item(id: id), item.isFlattenedPackage else { return name }
        return FlattenedPackage.renamed(item.name, to: name)
    }

    /// Where a change really goes. macOS calling a package by its name on the disk isn't a rename,
    /// and moving something onto itself isn't something a server can do.
    private static func serverLocation(
        _ asked: (parentID: String, name: String)?, of id: String, store: SyncStore
    ) throws -> (parentID: String, name: String)? {
        guard let asked, let item = try store.item(id: id), item.isFlattenedPackage else { return asked }
        let name = FlattenedPackage.renamed(item.name, to: asked.name)
        return name == item.name && asked.parentID == item.parentID ? nil : (asked.parentID, name)
    }

    /// `Report.numbers` and `Report.numbers.pkgf` land on the disk under one name, so a folder
    /// can't hold both. macOS answers this by picking another name, so it's nothing for a person
    /// to deal with, and it's checked before anything is recorded as a failure.
    private func checkNoTwin(
        of name: String, isFolder: Bool, in parentID: String, id: String? = nil
    ) throws {
        guard let twin = try store.child(of: parentID, named: FlattenedPackage.twin(of: name)),
              twin.id != id
        else { return }
        // A folder with that ending is only a folder, and the disk holds it under its own name.
        let endingIsOnAFolder = FlattenedPackage.isFlattened(name) ? isFolder : twin.kind == .directory
        guard !endingIsOnAFolder else { return }
        throw NameTaken(path: try store.path(of: twin.id), holder: twin)
    }

    /// Whether macOS can be told to leave something out of sync. It answers that with `deleteItem`,
    /// which can't be told from a person's delete, so anything that could be on the server would
    /// be taken from every device. This is only true of what can't be there, and doubt means no.
    /// - Parameter hasOptions: A re-import or a conflicting delete, whose identifier proves nothing.
    public static func isSafelyNew(
        id: String, name: String, parentID: String, hasOptions: Bool, store: SyncStore
    ) -> Bool {
        guard !hasOptions else { return false }
        do {
            guard try !store.isRecovering(), try store.item(id: id) == nil else { return false }
            return try store.child(of: parentID, named: name) == nil
        } catch {
            return false
        }
    }

    /// What to do with something that stays on this Mac, when macOS offers it again.
    public enum LocalOnly: Equatable, Sendable {
        case adopted(SyncItem)
        case leaveOut
        case tryLater
    }

    /// Asks the server, because only a direct answer can settle what a re-import offers.
    /// - Parameter mayAdopt: False for a link, which what's on the server can't stand in for.
    public func settleLocalOnly(id: String, name: String, parentID: String, mayAdopt: Bool) async -> LocalOnly {
        guard let path = (try? store.path(of: parentID))?.appending(name) else { return .tryLater }
        do {
            let remote = try await backend.item(at: path)
            guard mayAdopt, let saved = try? store.recordCreated(remote, in: parentID) else { return .tryLater }
            return .adopted(saved)
        } catch RemoteError.notFound {
            return Self.isSafelyNew(id: id, name: name, parentID: parentID, hasOptions: false, store: store)
                ? .leaveOut : .tryLater
        } catch {
            return .tryLater
        }
    }

    /// Records why a file didn't go. The extension calls this too, for a failure before any of
    /// this runs: connecting is shared by every file waiting, and it can fail for all of them.
    public static func note(
        failure error: Error, id: String, name: String, store: SyncStore, now: Date = Date()
    ) {
        if let remote = error as? RemoteError, remote.belongsOnAFile {
            if case .locked = remote {
                try? store.noteBusyFile(now: now)
            }
            try? store.recordFailure(id: id, name: name, message: remote.problem.stored, now: now)
        }
        // Everything fails in an outage, and it all goes through once the server's back.
        if (try? store.isOffline(now: now)) == true { return }
        let problem: FileProblem
        let canHold: Bool
        switch error {
        case is CancellationError:
            return
        case SyncError.recovering:
            problem = FileProblem(
                cause: "macOS is still checking this drive.",
                fix: "Nothing to do. This carries on when macOS finishes.")
            canHold = false
        case let remote as RemoteError:
            guard remote.canHoldAFile else { return }
            problem = remote.problem
            canHold = true
        default:
            // Saved in English, whatever language this process shows, so the app can translate it
            // when it's shown. Only the system's own errors come already in its language.
            problem = FileProblem(
                cause: (error as? any WordedError)?.englishDescription ?? error.localizedDescription,
                fix: "Press Try Again. If it keeps failing, export Diagnostics from Settings.")
            canHold = true
        }
        // The engine's words can quote an address, and this ends up on screen.
        let message = String(Diagnostics.redact(problem.stored).prefix(Self.longestReason))
        try? store.noteFailedAttempt(id: id, name: name, message: message, canHold: canHold, now: now)
    }

    private static let longestReason = 1_000

    /// How long to wait before a second look at something the server said wasn't there. Apache's
    /// gap during a save lasts only while one request runs, so a short wait usually passes it.
    static let secondLook: Duration = .milliseconds(300)

    /// Finder won't offer a write on a read-only drive, but every path still checks.
    private func checkWritable() throws {
        if isReadOnly() {
            throw RemoteError.readOnly
        }
    }

    /// Finder's own files stay local, so they never upload and never sit pending.
    public static func isHousekeeping(_ name: String) -> Bool {
        name == ".DS_Store" || name.hasPrefix("._")
    }

    private func checkName(_ name: String) throws {
        if RemotePath.isReservedName(name) {
            throw RemoteError.reservedName(name)
        }
    }

    /// Runs a change with an operation row written first, so a listing can't remove the item
    /// while its save is in flight. A crash leaves the row, and it expires on its own.
    private func tracking<Result>(
        _ id: String, _ kind: String, _ body: () async throws -> Result
    ) async throws -> Result {
        let operation = try store.beginOperation(item: id, kind: kind)
        defer { try? store.finishOperation(id: operation) }
        return try await body()
    }

    // MARK: Reading

    /// Downloads a file, and reports the version of exactly those bytes.
    public func fetch(id: String, to destination: URL) async throws -> SyncItem {
        let path = try store.path(of: id)
        // A server can call a folder not found, and macOS would drop what it holds for that.
        if try store.item(id: id)?.kind == .directory {
            throw RemoteError.failed(path, "This is a folder on the server, so it can't be downloaded as one file.")
        }
        let fetched: RemoteItem
        do {
            fetched = try await backend.verifiedDownload(path, to: destination)
        } catch RemoteError.notFound {
            // macOS drops its copy on "no such item", and one not-found proves little: Apache
            // removes a file for a moment while a save replaces it. So it's looked for again.
            try await Task.sleep(for: Self.secondLook)
            do {
                fetched = try await backend.verifiedDownload(path, to: destination)
            } catch RemoteError.notFound {
                noteToldGone(id)
                throw store.missing(id)
            }
        }
        let saved = try store.recordModified(id: id, entry: fetched)
        try? store.markLocal(id: id, size: fetched.size ?? 0)
        try? store.noteFinished(.downloaded, name: saved.name, size: fetched.size, now: clock())
        return saved
    }

    /// macOS is about to hear an item is gone, and drop its copy, while this Mac still has its row.
    /// Two looks can both land in moments without it, so the row is marked as doubted: if the
    /// next poll finds it after all, macOS is told it exists again. If it's really gone, the
    /// usual checks remove it.
    private func noteToldGone(_ id: String) {
        _ = try? store.recordMissingPass(id: id, now: clock())
    }

    /// What's at a path, or nil only after two direct not-founds, for the same reason as a download.
    private func lookTwice(at path: RemotePath) async throws -> RemoteItem? {
        do {
            return try await backend.item(at: path)
        } catch RemoteError.notFound {
            try await Task.sleep(for: Self.secondLook)
            do {
                return try await backend.item(at: path)
            } catch RemoteError.notFound {
                return nil
            }
        }
    }

    /// Uploads a file, then works out where it goes. A folder above it can move during a long
    /// upload, and the path from before would put the file back in a folder that's gone.
    private func save(
        _ contents: URL, baseVersion: String?, failOnConflict: Bool, details: FileDetails = FileDetails(),
        to path: () throws -> RemotePath
    ) async throws -> (result: SaveResult, path: RemotePath) {
        let inspected = LocalContents.inspect(contents)
        switch inspected {
        case .file:
            break
        case .not(let kind):
            throw RemoteError.notAPlainFile(try path(), kind)
        case .unreadable(let reason):
            throw RemoteError.unreadableHere(try path(), reason)
        }
        try await backend.checkName(try path())
        let staged = try await backend.stage(from: contents)
        do {
            let target = try path()
            // What was sent has to be what macOS asked to save, or it would be told a mix is safe.
            guard LocalContents.inspect(contents) == inspected else {
                throw RemoteError.unreadableHere(target, "it changed while it was being sent")
            }
            let result = try await backend.commit(
                staged, source: contents, to: target, baseVersion: baseVersion,
                failOnConflict: failOnConflict, details: details)
            if let missed = result.detailsMissed {
                onDetailsMissed(missed)
            }
            return (result, target)
        } catch {
            await backend.discard(staged)
            throw error
        }
    }

    // MARK: Changing

    /// Creates a file or folder.
    /// - Parameters:
    ///   - contents: The new file, or `nil` for a folder.
    ///   - mayAlreadyExist: macOS is re-importing, so an item already there is adopted.
    ///   - details: What macOS says about the file, kept beside it on servers that allow it.
    public func create(
        name: String, parentID: String, isFolder: Bool, contents: URL?, mayAlreadyExist: Bool,
        details: FileDetails = FileDetails()
    ) async throws -> SyncItem {
        try checkWritable()
        let id = SyncFailure.unsentID(name: name, parentID: parentID)
        try store.checkNotHeld(id: id)
        if !mayAlreadyExist {
            try checkNoTwin(of: name, isFolder: isFolder, in: parentID)
        }
        let item = try await recording(id: id, name: name) {
            try await createItem(
                name: name, parentID: parentID, isFolder: isFolder, contents: contents,
                mayAlreadyExist: mayAlreadyExist, details: details)
        }
        if contents != nil {
            try? store.noteFinished(.uploaded, name: item.name, size: item.size, now: clock())
        }
        if FlattenedPackage.isFlattened(name) {
            // The same document, from when it could only be offered as a folder.
            let earlier = SyncFailure.unsentID(name: FlattenedPackage.shownName(name), parentID: parentID)
            try? store.clearFailure(id: earlier, now: clock())
        }
        return item
    }

    private func createItem(
        name: String, parentID: String, isFolder: Bool, contents: URL?, mayAlreadyExist: Bool,
        details: FileDetails
    ) async throws -> SyncItem {
        func location() throws -> RemotePath {
            let parent: RemotePath
            do {
                parent = try store.path(of: parentID)
            } catch SyncError.itemNotFound where contents != nil || isFolder {
                // A peer deleted its folder, and this Mac confirmed it before macOS took that in.
                // These bytes, or what goes in this folder, exist only here, so it waits, listed
                // with why. A recovering database still says "recovering".
                throw RemoteError.parentMissing(RemotePath(name) ?? .root)
            }
            guard let path = parent.appending(name) else {
                throw RemoteError.failed(parent, "Invalid name")
            }
            return path
        }
        let path = try location()

        // A name can't be refused before this: it may be on the server already. Only a direct
        // not-found goes on, because macOS drops its copy on "no such item", and a failed request
        // says nothing about what's there.
        if mayAlreadyExist, contents == nil || isFolder {
            if let found = try await lookTwice(at: path) {
                return try store.recordCreated(found, in: parentID)
            }
            // Nothing there, so it's made below.
        }
        try checkName(name)

        let remote: RemoteItem
        if isFolder {
            try await backend.createDirectory(path, created: details.created)
            remote = try await backend.item(at: path)
        } else if let contents {
            let (result, _) = try await save(
                contents, baseVersion: nil, failOnConflict: false, details: details, to: location)
            // If the name was taken, our file is the conflict copy, and it takes that name.
            if let copy = result.conflictCopy {
                remote = try await backend.item(at: copy)
            } else {
                remote = result.item
            }
        } else {
            // During a recovery, nothing can say an item is gone.
            guard (try? store.isRecovering()) == false else { throw SyncError.recovering }
            throw RemoteError.notFound(path)
        }
        let saved = try store.recordCreated(remote, in: parentID)
        if isFolder {
            // macOS never lists a folder made here, so it has to count as in use from the start,
            // or a peer's file in it would wait for the next reconcile.
            try? store.markOpened(id: saved.id)
        } else if contents != nil {
            try? store.markLocal(id: saved.id, size: remote.size ?? 0)
        }
        return saved
    }

    /// Applies a local change.
    /// - Parameters:
    ///   - baseVersion: What macOS says this edit started from. This must never be read from
    ///     the database: a poll can move that on while an edit waits, and then a peer's save
    ///     would look like our base and be overwritten.
    ///   - newLocation: The new parent and name, if it moved or was renamed.
    ///   - contents: The new content, if it changed.
    ///   - shownAt: Where macOS has the item. An edit of an item this Mac no longer knows goes
    ///     back there.
    public func modify(
        id: String,
        baseVersion: String?,
        newLocation asked: (parentID: String, name: String)?,
        contents: URL?,
        failOnConflict: Bool,
        shownAt: (parentID: String, name: String)? = nil,
        details: FileDetails = FileDetails()
    ) async throws -> Outcome {
        if let contents, try store.item(id: id) == nil {
            return try await putBack(
                id: id, at: asked ?? shownAt, baseVersion: baseVersion, contents: contents,
                failOnConflict: failOnConflict, details: details)
        }
        let newLocation = try Self.serverLocation(asked, of: id, store: store)
        if newLocation == nil, contents == nil {
            return try Self.localChange(id: id, baseVersion: baseVersion, store: store)
        }
        try checkWritable()
        try Self.checkMayTry(id: id, newName: newLocation?.name, store: store)
        if let newLocation {
            try checkNoTwin(
                of: newLocation.name, isFolder: try store.item(id: id)?.kind == .directory,
                in: newLocation.parentID, id: id)
        }
        // The new name, because that's the one in Finder now.
        let name = newLocation?.name ?? (try? store.item(id: id)?.name) ?? id
        let outcome: Outcome
        do {
            outcome = try await recording(id: id, name: name) {
                try await tracking(id, "modify") {
                    try await applyChange(
                        id: id, baseVersion: baseVersion, newLocation: newLocation, contents: contents,
                        failOnConflict: failOnConflict, details: details)
                }
            }
        } catch RemoteError.alreadyExists where newLocation != nil {
            throw await nameTaken(at: newLocation!, by: id)
        }
        if contents != nil {
            try? store.noteFinished(.uploaded, name: outcome.item.name, size: outcome.item.size, now: clock())
        }
        return outcome
    }

    /// A rename onto a name the server already has. macOS can only rename one of the two if it
    /// knows the other, which may be a peer's new file this Mac hasn't listed yet.
    private func nameTaken(at location: (parentID: String, name: String), by id: String) async -> NameTaken {
        _ = try? await syncer.refresh(folderID: location.parentID)
        let holder = (try? store.child(of: location.parentID, named: location.name)).flatMap { $0 }
        let path = (try? store.path(of: location.parentID))?.appending(location.name) ?? .root
        return NameTaken(path: path, holder: holder?.id == id ? nil : holder)
    }

    /// An edit of a file this Mac stopped knowing: a peer deleted it, and two checks confirmed
    /// that before macOS took it in. These bytes are the only copy of the edit, and "no such item"
    /// would have macOS delete them, so the file goes back where macOS has it, under the same
    /// identifier, as an edit of a deleted file does.
    private func putBack(
        id: String, at place: (parentID: String, name: String)?, baseVersion: String?, contents: URL,
        failOnConflict: Bool, details: FileDetails
    ) async throws -> Outcome {
        guard let place else { throw store.missing(id) }
        if try store.isRecovering() { throw SyncError.recovering }
        try checkWritable()
        try Self.checkMayTry(id: id, newName: nil, store: store)
        let outcome = try await recording(id: id, name: place.name) {
            try await tracking(id, "modify") {
                guard try store.item(id: place.parentID)?.kind == .directory else {
                    // Its folder went too. It waits here, listed with why, and macOS keeps it.
                    throw RemoteError.parentMissing(RemotePath(place.name) ?? .root)
                }
                try checkName(place.name)
                let parent = try store.path(of: place.parentID)
                guard let path = parent.appending(place.name) else {
                    throw RemoteError.failed(parent, "Invalid name")
                }
                let (result, _) = try await save(
                    contents, baseVersion: baseVersion, failOnConflict: failOnConflict, details: details,
                    to: { path })
                // If a new file took the name meanwhile, this edit is the conflict copy, and the
                // item takes that name.
                let entry: RemoteItem
                if let copy = result.conflictCopy {
                    entry = try await backend.item(at: copy)
                } else {
                    entry = result.item
                }
                let saved = try store.recordRestored(id: id, entry: entry, in: place.parentID)
                try? store.markLocal(id: id, size: entry.size ?? 0)
                if result.conflictCopy != nil {
                    _ = try? await syncer.refresh(folderID: place.parentID)
                }
                return Outcome(item: saved, changedOtherItems: true)
            }
        }
        try? store.noteFinished(.uploaded, name: outcome.item.name, size: outcome.item.size, now: clock())
        return outcome
    }

    /// A tag, a date or a flag. These stay on this Mac, so the server isn't asked, and an outage
    /// can't leave them waiting. The extension calls this without connecting.
    public static func localChange(id: String, baseVersion: String?, store: SyncStore) throws -> Outcome {
        guard let item = try store.item(id: id) else { throw store.missing(id) }
        return Outcome(item: item, shouldFetchContent: isNotBase(item, baseVersion))
    }

    /// Whether the bytes on this Mac are something other than this item's version. macOS has to
    /// be told to fetch then. Without that it labels its old bytes with the newer version, and
    /// the next edit passes as an edit of a peer's save and overwrites it.
    private static func isNotBase(_ item: SyncItem, _ baseVersion: String?) -> Bool {
        item.kind == .file && baseVersion != String(decoding: ItemVersions.content(of: item), as: UTF8.self)
    }

    private func applyChange(
        id: String,
        baseVersion: String?,
        newLocation: (parentID: String, name: String)?,
        contents: URL?,
        failOnConflict: Bool,
        details: FileDetails
    ) async throws -> Outcome {
            var path = try store.path(of: id)
            var remote: RemoteItem?

            // A folder named like a package stays a folder. Saving over it would only make a
            // flat conflict copy beside it, once for every edit.
            if contents != nil, try store.item(id: id)?.kind == .directory {
                throw RemoteError.notAPlainFile(path, .folder)
            }

            if let newLocation {
                try checkName(newLocation.name)
                let parent = try store.path(of: newLocation.parentID)
                guard let destination = parent.appending(newLocation.name) else {
                    throw RemoteError.failed(path, "Invalid name")
                }
                try await backend.checkName(destination)
                let kind = try store.item(id: id)?.kind
                do {
                    let moved = try await moveLookingTwice(from: path, to: destination, baseVersion: baseVersion)
                    // A replay takes any folder it finds, because a folder has no version to prove
                    // it's the one that moved. A file can't have turned into one, so that's another
                    // item with the name.
                    guard moved.kind == kind else { throw RemoteError.alreadyExists(destination) }
                    remote = moved
                } catch RemoteError.notFound where contents != nil {
                    // A peer deleted it while this edit waited. The edit is the only copy of these
                    // bytes, so it's saved at the new name, as an edit of a deleted file is.
                } catch RemoteError.notFound(let missing) {
                    // No bytes to keep, so macOS hears it's gone, and drops its copy.
                    noteToldGone(id)
                    throw RemoteError.notFound(missing)
                }
                try store.recordMoved(id: id, to: newLocation.parentID, name: newLocation.name)
                path = destination
            }

            if let contents {
                let (result, committed) = try await saveFollowingMoves(
                    id: id, contents: contents, baseVersion: baseVersion, failOnConflict: failOnConflict,
                    details: details)
                path = committed
                remote = result.item
                if result.conflictCopy != nil {
                    // A peer saved first. Their version keeps the name, ours is now a conflict
                    // copy on the server, and macOS fetches their version.
                    let saved = try store.recordModified(id: id, entry: result.item)
                    if let parent = saved.parentID {
                        _ = try? await syncer.refresh(folderID: parent)
                    }
                    return Outcome(item: saved, shouldFetchContent: true, changedOtherItems: true)
                }
            }

            guard let remote else { throw RemoteError.failed(path, "Nothing to change") }
            let saved = try store.recordModified(id: id, entry: remote)
            if contents != nil {
                try? store.markLocal(id: id, size: remote.size ?? 0)
                return Outcome(item: saved)
            }
            // A move takes whatever the server has now, which may be a peer's newer version.
            return Outcome(item: saved, shouldFetchContent: Self.isNotBase(saved, baseVersion))
    }

    /// A rename of a file a peer is saving can land in Apache's moment without it, and the engine
    /// then says the source isn't there. One not-found proves little, so it's tried again first,
    /// as a download and a re-import look twice.
    private func moveLookingTwice(
        from source: RemotePath, to destination: RemotePath, baseVersion: String?
    ) async throws -> RemoteItem {
        do {
            return try await backend.move(from: source, to: destination, baseVersion: baseVersion)
        } catch RemoteError.notFound {
            try await Task.sleep(for: Self.secondLook)
        }
        return try await backend.move(from: source, to: destination, baseVersion: baseVersion)
    }

    /// A folder above can move between working out the path and committing. The bytes then land
    /// at the old path, in a folder the save made again, and macOS would be told its file holds
    /// bytes that are somewhere else. So it's saved again where the item is now, and the stray
    /// goes to the trash, where it can still be restored.
    private func saveFollowingMoves(
        id: String, contents: URL, baseVersion: String?, failOnConflict: Bool, details: FileDetails
    ) async throws -> (result: SaveResult, path: RemotePath) {
        var saved = try await save(
            contents, baseVersion: baseVersion, failOnConflict: failOnConflict, details: details
        ) {
            try store.path(of: id)
        }
        for _ in 1...2 where try store.path(of: id) != saved.path {
            let stray = saved
            saved = try await save(
                contents, baseVersion: baseVersion, failOnConflict: failOnConflict, details: details
            ) {
                try store.path(of: id)
            }
            if stray.result.conflictCopy == nil {
                try? await backend.trash(stray.path, baseVersion: stray.result.item.versionID)
            }
        }
        // Still moving after all that, so macOS can replay this once things have settled.
        guard try store.path(of: id) == saved.path else { throw RemoteError.locked(saved.path) }
        return saved
    }

    /// Moves an item to the server's trash, refusing if it isn't the version macOS last saw.
    public func delete(id: String, baseVersion: String?) async throws {
        try checkWritable()
        guard let item = try store.item(id: id) else {
            // A replay finds its item already gone. During a recovery that proves nothing, and
            // saying it's done would leave the file on the server for good.
            if try store.isRecovering() { throw SyncError.recovering }
            return
        }
        try await recording(id: id, name: item.name) {
            try await tracking(id, "delete") {
                let path = try store.path(of: id)
                try await backend.trash(path, baseVersion: item.kind == .directory ? nil : baseVersion)
                try store.recordDeleted(id: id)
            }
        }
        try? store.noteFinished(.deleted, name: item.name, size: item.size, now: clock())
    }
}
