// Apache 2 license - developer@infinitecontext.com

import CloudCore
import FileProvider
import MountKit
import RemoteEngine
import SyncCore

/// Where a device keeps its drives, their passwords and their databases, and who it is. The Mac
/// and the iPhone keep them in different places, and the iPhone only ever reads.
public struct DrivePlace: Sendable {
    /// The drives and their passwords.
    public let drives: @Sendable () throws -> DriveStore
    /// Where a drive's database and its backup are.
    public let database: @Sendable (DriveStore, UUID) throws -> (url: URL, backup: URL)
    /// Who's saving, for staging files and conflict copy names. Nil on a device that never saves.
    public let device: @Sendable (DriveStore) throws -> DeviceInfo?
    /// Refuses every change, whatever the drive's own settings say.
    public let isAlwaysReadOnly: Bool
    /// Whether this extension may serve a drive at all.
    public let serves: @Sendable (Connection) -> Bool

    public init(
        drives: @escaping @Sendable () throws -> DriveStore,
        database: @escaping @Sendable (DriveStore, UUID) throws -> (url: URL, backup: URL),
        device: @escaping @Sendable (DriveStore) throws -> DeviceInfo?,
        isAlwaysReadOnly: Bool,
        serves: @escaping @Sendable (Connection) -> Bool
    ) {
        self.drives = drives
        self.database = database
        self.device = device
        self.isAlwaysReadOnly = isAlwaysReadOnly
        self.serves = serves
    }
}

/// What's known about a drive with no server needed, so Finder keeps working in an outage,
/// even if macOS starts this extension again during one.
public struct LocalDrive: Sendable {
    public let id: UUID
    public let saved: DriveStore
    public let connection: Connection
    public let store: SyncStore
    /// Read each time, because a setting can change while the extension is running.
    public let settings: @Sendable () -> DriveSettings
    public let isReadOnly: @Sendable () -> Bool

    /// Reads what's the same for every item once, because a page can hold thousands of them and
    /// settings come from a file.
    public func presenter() -> @Sendable (SyncItem) -> FileProviderItem {
        let isReadOnly = isReadOnly()
        let store = store
        #if os(macOS)
        let showsUnavailable = (try? store.showsUnavailable()) ?? false
        return { item in
            let isUnavailable = item.kind == .file && showsUnavailable
                && !((try? store.hasLocalCopy(id: item.id)) ?? true)
            return FileProviderItem(
                item, isReadOnly: isReadOnly, isUnavailable: isUnavailable,
                isFailed: (try? store.hasFailure(id: item.id)) ?? false)
        }
        #else
        // The iPhone shows no badges, so these would only change versions for nothing. What a
        // person set on an item here goes back with it.
        return { item in
            FileProviderItem(item, isReadOnly: isReadOnly, marks: (try? store.marks(id: item.id)) ?? nil)
        }
        #endif
    }

    public func present(_ item: SyncItem) -> FileProviderItem {
        presenter()(item)
    }

    /// The item with this ID as it stands here, if it's known.
    public func present(id: String) -> FileProviderItem? {
        guard let item = try? store.item(id: id) else { return nil }
        return present(item)
    }
}

/// The open connection and state for a drive.
public struct OpenDrive: Sendable {
    public let local: LocalDrive
    public let engine: RemoteEngine
    public let syncer: Syncer
    public let mutations: Mutations

    public var store: SyncStore { local.store }
    public var settings: @Sendable () -> DriveSettings { local.settings }

    public func presenter() -> @Sendable (SyncItem) -> FileProviderItem {
        local.presenter()
    }

    public func present(_ item: SyncItem) -> FileProviderItem {
        local.present(item)
    }
}

/// Reaches a drive once, on first use. Requests arrive together when macOS starts the extension,
/// so they share the work.
public actor Connector {
    private let domainIdentifier: String
    private let place: DrivePlace
    private var loading: Task<LocalDrive, Error>?
    private var opening: Task<OpenDrive, Error>?
    private var openedRevision = 0

    public init(domainIdentifier: String, place: DrivePlace) {
        self.domainIdentifier = domainIdentifier
        self.place = place
    }

    /// The drive's database, which needs no connection.
    public func local() async throws -> LocalDrive {
        if let loading {
            let drive = try await loading.value
            if drive.store.isCurrent {
                return drive
            }
            // The app repaired the database, so this handle is on a file that's been set aside.
            self.loading = nil
            opening = nil
        }
        let identifier = domainIdentifier
        let place = place
        let task = Task { try await Self.load(domainIdentifier: identifier, place: place) }
        loading = task
        do {
            return try await task.value
        } catch {
            // Nothing is kept from a failure, so the next request tries again.
            loading = nil
            throw error
        }
    }

    /// The drive with its connection. Once the app has found the server unreachable, this fails
    /// at once, so Finder isn't left waiting on a connection that will time out.
    public func open() async throws -> OpenDrive {
        let local = try await local()
        if (try? local.store.isOffline()) == true {
            throw RemoteError.unreachable("The drive is offline.", reason: .markedOffline)
        }
        // A connection made before a new password was saved would go on failing. Calls already
        // running on it finish, and each one is safe to replay if the server refuses it.
        let revision = (try? local.store.signInRevision()) ?? openedRevision
        if let opening, revision == openedRevision {
            return try await opening.value
        }
        openedRevision = revision
        let place = place
        let task = Task { try await Self.connect(local, place: place) }
        opening = task
        do {
            return try await task.value
        } catch {
            opening = nil
            throw error
        }
    }

    /// The same, for saving a file. Connecting is shared by every file waiting, and it fails before
    /// anything else can note why, so a failure here is recorded on the file.
    public func open(forFile id: String, named name: String, local: LocalDrive) async throws -> OpenDrive {
        do {
            return try await open()
        } catch {
            Mutations.note(failure: error, id: id, name: name, store: local.store)
            throw error
        }
    }

    private static func load(domainIdentifier: String, place: DrivePlace) async throws -> LocalDrive {
        let saved = try place.drives()
        guard let id = UUID(uuidString: domainIdentifier),
              let connection = try saved.connection(id: id),
              place.serves(connection)
        else { throw NSFileProviderError(.providerDomainNotFound) }
        // A recovery is finished by the app, which can walk the server first.
        let files = try place.database(saved, id)
        let opening = try SyncStore.opening(url: files.url, backup: files.backup)
        if opening.recovery != .none {
            saved.diagnostics.record("\(connection.displayName): database recovered: \(opening.recovery)")
        }
        let current: @Sendable () -> Connection = { (try? saved.connection(id: id)) ?? connection }
        let isAlwaysReadOnly = place.isAlwaysReadOnly
        return LocalDrive(
            id: id, saved: saved, connection: connection, store: opening.store,
            settings: { current().settings }, isReadOnly: { isAlwaysReadOnly || current().isReadOnly })
    }

    private static func connect(_ local: LocalDrive, place: DrivePlace) async throws -> OpenDrive {
        let device = try place.device(local.saved)
        // This runs again after a trusted host key or a change to read-only, and the copy from when
        // the drive loaded knows about neither, so it would go on failing until macOS restarted this.
        var connection = try local.saved.connection(id: local.id) ?? local.connection
        if place.isAlwaysReadOnly {
            // The engine refuses every change too, so not even a mistake up here can write.
            connection.settings.isReadOnly = true
        }
        let engine = try await RemoteEngine(
            connection: connection, credentials: local.saved.credentials(for: local.id), device: device)
        let syncer = Syncer(store: local.store, backend: engine)
        return OpenDrive(
            local: local, engine: engine, syncer: syncer,
            mutations: Mutations(
                backend: engine, store: local.store, syncer: syncer, isReadOnly: local.isReadOnly,
                onDetailsMissed: { [name = connection.displayName] in Trace.detailsMissed($0, drive: name) }))
    }
}
