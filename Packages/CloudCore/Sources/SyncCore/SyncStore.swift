// Apache 2 license - developer@infinitecontext.com

import CloudCore
import Foundation

/// One file or folder as this device knows it.
public struct SyncItem: Equatable, Sendable {
    public var id: String
    public var parentID: String?
    public var name: String
    public var kind: RemoteItem.Kind
    public var size: Int64?
    public var modified: Date?
    public var version: String
    /// The server version's ID, or `nil` if the server gives no evidence of one.
    public var versionID: String?
    /// The folder generation, for folders only.
    public var generation: Int64
    /// A folder kept downloaded, with everything inside it.
    public var isPinned = false
    // From the file's details, on servers that keep them. None of these is part of a version.
    public var ownModified: Date?
    public var created: Date?
    public var checksum: String?

    public static let rootID = "root"

    public var isRoot: Bool { id == Self.rootID }

    /// A package macOS has flattened into one file. Stays on this Mac until bringing one back has
    /// been proved on a mounted drive, because a document that can't come back is lost to its owner.
    public var isFlattenedPackage: Bool {
        kind == .file && FlattenedPackage.isFlattened(name)
    }

    public init(
        id: String,
        parentID: String?,
        name: String,
        kind: RemoteItem.Kind,
        size: Int64?,
        modified: Date?,
        version: String,
        versionID: String?,
        generation: Int64,
        isPinned: Bool = false,
        ownModified: Date? = nil,
        created: Date? = nil,
        checksum: String? = nil
    ) {
        self.ownModified = ownModified
        self.created = created
        self.checksum = checksum
        self.id = id
        self.parentID = parentID
        self.name = name
        self.kind = kind
        self.size = size
        self.modified = modified
        self.version = version
        self.versionID = versionID
        self.generation = generation
        self.isPinned = isPinned
    }
}

/// A position in the change log. An anchor from another epoch, or one that's been pruned,
/// can't be continued, and macOS re-enumerates instead.
public struct SyncAnchor: Equatable, Sendable {
    public var epoch: String
    public var sequence: Int64

    public init(epoch: String, sequence: Int64) {
        self.epoch = epoch
        self.sequence = sequence
    }

    public var encoded: Data { Data("\(epoch):\(sequence)".utf8) }

    public init?(encoded data: Data) {
        let parts = String(decoding: data, as: UTF8.self).split(separator: ":", maxSplits: 1)
        guard parts.count == 2, let sequence = Int64(parts[1]) else { return nil }
        self.init(epoch: String(parts[0]), sequence: sequence)
    }
}

public struct SyncChanges: Equatable, Sendable {
    public var updated: [SyncItem]
    public var deleted: [String]
    public var anchor: SyncAnchor
    /// Whether more changes follow in another batch.
    public var moreComing = false
}

public enum SyncError: Error, Equatable {
    case anchorExpired
    case itemNotFound(String)
    /// The database is being rebuilt, so it can't yet say what exists. macOS treats "no such item"
    /// as deleted on the server and drops its copy, so this has to stay a "try later".
    case recovering
    /// The database comes from a newer version of the app, and is left alone.
    case newerDatabase
    /// A damaged database couldn't be set aside or replaced safely, so nothing was touched.
    case repairFailed
    /// The server holds more folders than a walk can take, so a recovery can't finish.
    case treeTooLarge
    /// This file kept failing, so it waits on this Mac until a person asks for it to be tried.
    case held
}

/// A file that couldn't sync, for the menu's list.
public struct SyncFailure: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var message: String
    public var date: Date

    private static let unsentPrefix = "new:"

    /// A file that never reached the server has no item, so its ID says which folder it's in.
    public var isUnsentFile: Bool {
        id.hasPrefix(Self.unsentPrefix)
    }

    fileprivate var unsentParentID: String {
        String(id.dropFirst(Self.unsentPrefix.count).dropLast(name.count + 1))
    }

    /// What a file that isn't on the server yet goes by. It has no item, so a renamed file is a
    /// different one, which is what lets a rename start it afresh.
    public static func unsentID(name: String, parentID: String) -> String {
        "\(unsentPrefix)\(parentID)/\(name)"
    }
}

/// A file that keeps failing. macOS retries for as long as it takes, so this is how a person
/// finds out, and how a file that can't get through stops being tried.
public struct SyncAttempt: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var message: String
    public var firstFailed: Date
    public var lastFailed: Date
    public var count: Int
    /// It's waiting on this Mac until a person asks for it to be tried.
    public var isHeld: Bool

    /// Both, so a burst of quick retries can't hold a file, and neither can two failures days
    /// apart. It's longer than a claim left by a crash lasts, because that clears by itself.
    fileprivate var hasHadEnoughChances: Bool {
        count >= SyncStore.attemptsBeforeHolding
            && lastFailed.timeIntervalSince(firstFailed) >= SyncStore.holdAfter
    }
}

/// Something finished, for showing what's been done.
public struct SyncActivity: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable {
        case uploaded
        case downloaded
        case deleted
    }

    public var id: Int64
    public var kind: Kind
    public var name: String
    public var size: Int64?
    public var date: Date
}

/// How much has been done. These keep counting after the list of what's recent moves on.
public struct SyncTotals: Equatable, Sendable {
    public var uploaded = 0
    public var downloaded = 0
    public var deleted = 0
    public var since: Date?

    public init() {}

    public var finished: Int {
        uploaded + downloaded + deleted
    }
}

/// A file on its way to or from the server right now.
public struct SyncTransfer: Equatable, Sendable, Identifiable {
    public enum Direction: String, Sendable {
        case upload
        case download
    }

    public var id: String
    public var name: String
    public var direction: Direction
    public var done: Int64
    public var total: Int64
    public var started: Date
    public var updated: Date

    /// Averaged over the whole transfer, because a figure that jumps every second says less.
    public var bytesPerSecond: Double? {
        let elapsed = updated.timeIntervalSince(started)
        return elapsed >= 1 && done > 0 ? Double(done) / elapsed : nil
    }
}

/// Writes a transfer's progress down for the app to show. The engine reports far more often than
/// anyone can read, and each write reaches the disk, so this keeps to about once a second. A write
/// that fails only costs the display, so it never touches the transfer.
///
/// Nothing is written until the first report, because reports only come once the engine call is
/// running. macOS hands over more files than may move at once, and one waiting its turn isn't
/// moving: it once had its record cleared as a dead process's, and then moved unseen.
public final class TransferReporter: @unchecked Sendable {
    private static let interval: TimeInterval = 1

    private let store: SyncStore
    private let id = UUID().uuidString
    private let name: String
    private let direction: SyncTransfer.Direction
    private let total: Int64
    private let clock: @Sendable () -> Date
    /// Held through each write, so a finish can't land between a report and its write and leave
    /// the record behind.
    private let lock = NSLock()
    private var started: Date?
    private var lastWrite: Date?
    private var highest: Int64 = 0
    private var isFinished = false

    public init(
        store: SyncStore, name: String, direction: SyncTransfer.Direction, total: Int64,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.name = name
        self.direction = direction
        self.total = total
        self.clock = clock
    }

    /// A save is several engine calls, and each counts from zero, so only the highest figure
    /// counts. Otherwise a bar would fall back to nothing as the upload ended.
    public func update(_ done: Int64) {
        let now = clock()
        lock.withLock {
            guard !isFinished else { return }
            highest = max(highest, done)
            if let lastWrite, now.timeIntervalSince(lastWrite) < Self.interval { return }
            let firstReport = started ?? now
            started = firstReport
            lastWrite = now
            try? store.recordTransfer(
                id: id, name: name, direction: direction, done: highest, total: total,
                started: firstReport, now: now)
        }
    }

    public func finish() {
        lock.withLock {
            isFinished = true
            if started != nil {
                try? store.finishTransfer(id: id)
            }
        }
    }
}

/// The durable state of one drive: item identities, the last-seen server snapshot, and
/// the change log macOS reads. Rows store a parent and a name, never a full path, so
/// renaming a folder touches one row.
public final class SyncStore: Sendable {
    private let database: Database
    private let url: URL
    /// Which file this store has open, because another process can replace the one at `url`.
    private let fileIdentity: FileIdentity?

    private struct FileIdentity: Equatable, Sendable {
        var device: Int
        var inode: UInt64

        init?(_ url: URL) {
            var info = stat()
            guard stat(url.path, &info) == 0 else { return nil }
            device = Int(info.st_dev)
            inode = UInt64(info.st_ino)
        }
    }

    /// Whether this is still the drive's database. After another process repairs it, the file at
    /// the path is a new one, and writing to the old one would be writing to nothing.
    public var isCurrent: Bool {
        FileIdentity(url) == fileIdentity
    }

    /// Changes older than this are pruned, which expires anchors that far behind.
    public static let changeLogLifetime: TimeInterval = 30 * 86_400
    public static let tombstoneLifetime: TimeInterval = 7 * 86_400
    /// Deeper than any real folder tree, and a guard against a corrupt one.
    private static let maximumDepth = 4096
    /// An operation this old belongs to a process that died, and macOS will replay it.
    private static let operationLifetime: TimeInterval = 86_400

    /// The schema this version of the app writes. Upgrades only ever go forward.
    private static let schemaVersion: Int64 = 3

    public init(url: URL) throws {
        self.url = url
        database = try Database(url: url)
        fileIdentity = FileIdentity(url)
        let version = try database.execute("PRAGMA user_version").first?.integer("user_version") ?? 0
        guard version <= Self.schemaVersion else { throw SyncError.newerDatabase }
        let hasItems = !(try database.execute(
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'items'").isEmpty)
        if hasItems && version < Self.schemaVersion {
            // A copy first, because this database holds the only map of IDs to server paths. A
            // version of zero with tables in it is an old database, not a new one.
            let backup = url.deletingPathExtension().appendingPathExtension("before-upgrade")
            try backUp(to: backup)
        }
        try createSchema()
        try migrate(from: version)
    }

    /// What it took to open a drive's database.
    public enum Recovery: Equatable, Sendable {
        case none
        case restoredFromBackup
        case startedAgain
    }

    /// Opens a drive's database. If it's damaged or missing, this falls back to the daily backup,
    /// or to an empty database that the next poll fills from the server. Either way the drive
    /// is marked as needing a rebuild, which the app does once it can reach the server.
    /// Unsent files don't depend on this: macOS holds them, with their base versions.
    public static func opening(url: URL, backup: URL) throws -> (store: SyncStore, recovery: Recovery) {
        try opening(url: url, backup: backup, beforeReplacing: nil)
    }

    /// - Parameter beforeReplacing: For tests: runs with the replacement, just before it takes the
    ///   database's name.
    static func opening(
        url: URL, backup: URL, beforeReplacing: ((URL) throws -> Void)?
    ) throws -> (store: SyncStore, recovery: Recovery) {
        let files = FileManager.default
        if files.fileExists(atPath: url.path), !isEmptied(url), let store = try intact(url) {
            remember(url)
            return (store, .none)
        }

        // The app and the extension can both get here, and only one may repair. The other waits,
        // and finds the repair done.
        let lock = try RepairLock(url)
        defer { lock.release() }
        if files.fileExists(atPath: url.path) {
            if !isEmptied(url), let store = try intact(url) {
                remember(url)
                return (store, .none)
            }
        } else if !files.fileExists(atPath: backup.path), !files.fileExists(atPath: marker(for: url).path) {
            // Nothing was ever here, which is simply a new drive.
            let store = try SyncStore(url: url)
            remember(url)
            return (store, .none)
        }
        // This includes a log left behind by a database that's gone, which a new database would
        // otherwise try to read as its own.
        try setAside(url)

        // The replacement is made under another name and flagged there. Only then does it take
        // the database's name, so a crash, or the other process opening it meanwhile, never finds
        // a restored or empty database that looks settled, and tells macOS what it holds is gone.
        let replacement = URL(fileURLWithPath: url.path + ".rebuilding")
        try removeDatabase(at: replacement)
        var recovery = Recovery.startedAgain
        if files.fileExists(atPath: backup.path) {
            try files.copyItem(at: backup, to: replacement)
            if let restored = try intact(replacement) {
                // Anchors macOS holds may be ahead of this copy, so they have to expire.
                try restored.startNewEpoch()
                try restored.setNeedsRebuild(true)
                recovery = .restoredFromBackup
            } else {
                try removeDatabase(at: replacement)
            }
        }
        if recovery == .startedAgain {
            try SyncStore(url: replacement).setNeedsRebuild(true)
        }
        // Every connection to the replacement is closed by now, so its log is in the file.
        try beforeReplacing?(replacement)
        // Its log first: until the file itself arrives, the other process finds nothing and waits.
        for suffix in ["-wal", "-shm", ""] where files.fileExists(atPath: replacement.path + suffix) {
            try files.moveItem(atPath: replacement.path + suffix, toPath: url.path + suffix)
        }
        let store = try SyncStore(url: url)
        remember(url)
        return (store, recovery)
    }

    /// SQLite takes an empty file for a new database. For a drive that has had one, it's a loss,
    /// and a new database there would look settled. A log with something in it isn't empty.
    private static func isEmptied(_ url: URL) -> Bool {
        func size(_ path: String) -> Int64? {
            ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value
        }
        return size(url.path) == 0 && (size(url.path + "-wal") ?? 0) == 0
            && FileManager.default.fileExists(atPath: marker(for: url).path)
    }

    /// Removes a database and its sidecars, such as a replacement a crash left half made.
    private static func removeDatabase(at url: URL) throws {
        let files = FileManager.default
        for suffix in ["", "-wal", "-shm"] where files.fileExists(atPath: url.path + suffix) {
            try files.removeItem(atPath: url.path + suffix)
        }
    }

    /// Says a drive has had a database, so one that vanishes along with its backup is a loss to
    /// recover from, not a new drive.
    private static func marker(for url: URL) -> URL {
        URL(fileURLWithPath: url.path + ".known")
    }

    private static func remember(_ url: URL) {
        let marker = marker(for: url)
        if !FileManager.default.fileExists(atPath: marker.path) {
            FileManager.default.createFile(atPath: marker.path, contents: nil)
        }
    }

    /// Serializes repairs between the app and its extension.
    private struct RepairLock {
        private let descriptor: Int32

        init(_ url: URL) throws {
            descriptor = open(url.path + ".lock", O_CREAT | O_RDWR, 0o600)
            guard descriptor >= 0, flock(descriptor, LOCK_EX) == 0 else {
                if descriptor >= 0 { close(descriptor) }
                throw SyncError.repairFailed
            }
        }

        func release() {
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }
    }

    /// A store if the file is sound, nil if it's damaged. Anything else, such as a database from
    /// a newer version or a busy one, is an error, because those files must not be replaced.
    private static func intact(_ url: URL) throws -> SyncStore? {
        do {
            let store = try SyncStore(url: url)
            let check = try store.database.execute("PRAGMA quick_check(1)")
            return check.first?.text("quick_check") == "ok" ? store : nil
        } catch Database.DatabaseError.damaged {
            return nil
        }
    }

    /// Keeps a damaged database for diagnosis, out of SQLite's way. Its sidecars go with it,
    /// because a database apart from its log is a different database. If this can't be done, the
    /// repair stops: restoring on top of a file that's still there could lose it.
    private static func setAside(_ url: URL) throws {
        let files = FileManager.default
        for suffix in ["", "-wal", "-shm"] where files.fileExists(atPath: url.path + suffix) {
            let kept = url.path + ".damaged" + suffix
            try? files.removeItem(atPath: kept)
            try files.moveItem(atPath: url.path + suffix, toPath: kept)
        }
    }

    private func startNewEpoch() throws {
        try database.execute("UPDATE meta SET value = ? WHERE key = 'epoch'", [.text(UUID().uuidString)])
    }

    /// Every column added to `items` since the first version. `CREATE TABLE IF NOT EXISTS` leaves
    /// an old table as it is, so each one is checked for, not assumed from the version number.
    private static let addedItemColumns = [
        ("version", "TEXT NOT NULL DEFAULT ''"),
        ("versionID", "TEXT"),
        ("generation", "INTEGER NOT NULL DEFAULT 0"),
        ("last_listed", "REAL"),
        ("last_opened", "REAL"),
        ("missing_passes", "INTEGER NOT NULL DEFAULT 0"),
        ("missing_since", "REAL"),
        ("pinned", "INTEGER NOT NULL DEFAULT 0"),
        ("own_modified", "REAL"),
        ("created", "REAL"),
        ("checksum", "TEXT"),
    ]

    private func migrate(from version: Int64) throws {
        try database.transaction {
            let columns = Set(try database.execute("PRAGMA table_info(items)").compactMap { $0.text("name") })
            for (name, definition) in Self.addedItemColumns where !columns.contains(name) {
                try database.execute("ALTER TABLE items ADD COLUMN \(name) \(definition)")
            }
            try database.execute("PRAGMA user_version = \(Self.schemaVersion)")
        }
    }

    private func createSchema() throws {
        try database.transaction {
            try database.execute("""
                CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT NOT NULL)
                """)
            try database.execute("""
                CREATE TABLE IF NOT EXISTS items(
                    id TEXT PRIMARY KEY,
                    parent TEXT,
                    name TEXT NOT NULL,
                    kind INTEGER NOT NULL,
                    size INTEGER,
                    modified REAL,
                    version TEXT NOT NULL DEFAULT '',
                    versionID TEXT,
                    generation INTEGER NOT NULL DEFAULT 0,
                    last_listed REAL,
                    last_opened REAL,
                    missing_passes INTEGER NOT NULL DEFAULT 0,
                    missing_since REAL,
                    pinned INTEGER NOT NULL DEFAULT 0,
                    own_modified REAL,
                    created REAL,
                    checksum TEXT,
                    UNIQUE(parent, name))
                """)
            try database.execute("""
                CREATE TABLE IF NOT EXISTS failures(
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    message TEXT NOT NULL,
                    at REAL NOT NULL)
                """)
            try database.execute("""
                CREATE TABLE IF NOT EXISTS changes(
                    sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                    item TEXT NOT NULL,
                    deleted INTEGER NOT NULL,
                    created REAL NOT NULL)
                """)
            try database.execute("""
                CREATE TABLE IF NOT EXISTS tombstones(
                    parent TEXT NOT NULL,
                    name TEXT NOT NULL,
                    version TEXT NOT NULL,
                    deleted_at REAL NOT NULL,
                    PRIMARY KEY(parent, name, version))
                """)
            try database.execute("""
                CREATE TABLE IF NOT EXISTS local_copies(
                    id TEXT PRIMARY KEY,
                    size INTEGER NOT NULL,
                    last_used REAL NOT NULL)
                """)
            try database.execute("""
                CREATE TABLE IF NOT EXISTS operations(
                    id TEXT PRIMARY KEY,
                    item TEXT NOT NULL,
                    kind TEXT NOT NULL,
                    started REAL NOT NULL)
                """)
            try database.execute("""
                CREATE TABLE IF NOT EXISTS attempts(
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    message TEXT NOT NULL,
                    first_failed REAL NOT NULL,
                    last_failed REAL NOT NULL,
                    count INTEGER NOT NULL,
                    held INTEGER NOT NULL DEFAULT 0)
                """)
            try database.execute("""
                CREATE TABLE IF NOT EXISTS activity(
                    sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                    kind TEXT NOT NULL,
                    name TEXT NOT NULL,
                    size INTEGER,
                    at REAL NOT NULL)
                """)
            try database.execute("""
                CREATE TABLE IF NOT EXISTS transfers(
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    direction TEXT NOT NULL,
                    done INTEGER NOT NULL,
                    total INTEGER NOT NULL,
                    started REAL NOT NULL,
                    updated REAL NOT NULL)
                """)
            // What a person set on an item on this device. Created on open, like every table here,
            // so an older database simply gains it.
            try database.execute("""
                CREATE TABLE IF NOT EXISTS marks(
                    id TEXT PRIMARY KEY,
                    last_used REAL,
                    tags TEXT,
                    favorite_rank INTEGER)
                """)
            let epoch = try database.execute("SELECT value FROM meta WHERE key = 'epoch'")
            if epoch.isEmpty {
                try database.execute(
                    "INSERT INTO meta(key, value) VALUES ('epoch', ?)", [.text(UUID().uuidString)])
            }
            try database.execute("""
                INSERT OR IGNORE INTO items(id, parent, name, kind)
                VALUES ('root', NULL, '', 1)
                """)
        }
    }

    private func item(from row: Database.Row) -> SyncItem? {
        guard let id = row.text("id"), let name = row.text("name"), let kind = row.integer("kind") else {
            return nil
        }
        return SyncItem(
            id: id,
            parentID: row.text("parent"),
            name: name,
            kind: kind == 1 ? .directory : .file,
            size: row.integer("size"),
            modified: row.real("modified").map(Date.init(timeIntervalSince1970:)),
            version: row.text("version") ?? "",
            versionID: row.text("versionID"),
            generation: row.integer("generation") ?? 0,
            isPinned: row.integer("pinned") == 1,
            ownModified: row.real("own_modified").map(Date.init(timeIntervalSince1970:)),
            created: row.real("created").map(Date.init(timeIntervalSince1970:)),
            checksum: row.text("checksum"))
    }

    // MARK: Reading

    public func item(id: String) throws -> SyncItem? {
        try database.execute("SELECT * FROM items WHERE id = ?", [.text(id)]).first.flatMap(item(from:))
    }

    public func children(of parentID: String) throws -> [SyncItem] {
        try database.execute(
            "SELECT * FROM items WHERE parent = ? ORDER BY name", [.text(parentID)]
        ).compactMap(item(from:))
    }

    public func child(of parentID: String, named name: String) throws -> SyncItem? {
        try database.execute(
            "SELECT * FROM items WHERE parent = ? AND name = ?", [.text(parentID), .text(name)]
        ).first.flatMap(item(from:))
    }

    /// Every known item except the root, which is the working set macOS tracks.
    public func allItems() throws -> [SyncItem] {
        try database.execute("SELECT * FROM items WHERE id != 'root'").compactMap(item(from:))
    }

    /// One page of the working set, in a stable order, so a huge drive goes out in batches.
    public func allItems(after id: String?, limit: Int) throws -> [SyncItem] {
        try database.execute(
            "SELECT * FROM items WHERE id != 'root' AND id > ? ORDER BY id LIMIT ?",
            [.text(id ?? ""), .integer(Int64(clamping: limit))]
        ).compactMap(item(from:))
    }

    /// One page of a folder, in a stable order.
    public func children(of parentID: String, after id: String?, limit: Int) throws -> [SyncItem] {
        try database.execute(
            "SELECT * FROM items WHERE parent = ? AND id > ? ORDER BY id LIMIT ?",
            [.text(parentID), .text(id ?? ""), .integer(Int64(clamping: limit))]
        ).compactMap(item(from:))
    }

    public func path(of id: String) throws -> RemotePath {
        var components: [String] = []
        var current = id
        while current != SyncItem.rootID {
            // A corrupt parent link could form a loop, and this must not spin forever.
            guard components.count < Self.maximumDepth,
                  let item = try item(id: current), let parent = item.parentID
            else {
                throw missing(id)
            }
            components.insert(item.name, at: 0)
            current = parent
        }
        guard let path = RemotePath(components.joined(separator: "/")) else {
            throw missing(id)
        }
        return path
    }

    // MARK: Anchors and changes

    private func epoch() throws -> String {
        try database.execute("SELECT value FROM meta WHERE key = 'epoch'").first?.text("value") ?? ""
    }

    /// Pruning removes rows, so the highest row alone could take the anchor backwards.
    public func currentAnchor() throws -> SyncAnchor {
        let rows = try database.execute("SELECT MAX(sequence) AS latest FROM changes")
        let latest = max(rows.first?.integer("latest") ?? 0, try oldestRetainedSequence())
        return SyncAnchor(epoch: try epoch(), sequence: latest)
    }

    private func oldestRetainedSequence() throws -> Int64 {
        let value = try database.execute("SELECT value FROM meta WHERE key = 'pruned'").first?.text("value")
        return value.flatMap(Int64.init) ?? 0
    }

    /// The changes after an anchor, up to a limit so a large catch-up goes out in batches.
    /// One transaction, so the log and the items it names match.
    public func changes(since anchor: SyncAnchor, limit: Int = .max) throws -> SyncChanges {
        try database.transaction {
            guard anchor.epoch == (try epoch()), anchor.sequence >= (try oldestRetainedSequence()) else {
                throw SyncError.anchorExpired
            }
            let rows = try database.execute(
                "SELECT * FROM changes WHERE sequence > ? ORDER BY sequence LIMIT ?",
                [.integer(anchor.sequence), .integer(Int64(clamping: limit))])

            // Only the latest change to each item matters.
            var latest: [String: Bool] = [:]
            var sequence = anchor.sequence
            for row in rows {
                guard let id = row.text("item"), let number = row.integer("sequence") else { continue }
                latest[id] = row.integer("deleted") == 1
                sequence = number
            }
            var updated: [SyncItem] = []
            var deleted: [String] = []
            for (id, wasDeleted) in latest {
                if !wasDeleted, let item = try item(id: id) {
                    updated.append(item)
                } else {
                    deleted.append(id)
                }
            }
            let remaining = try database.execute(
                "SELECT 1 FROM changes WHERE sequence > ? LIMIT 1", [.integer(sequence)])
            return SyncChanges(
                updated: updated.sorted { $0.id < $1.id },
                deleted: deleted.sorted(),
                anchor: SyncAnchor(epoch: anchor.epoch, sequence: sequence),
                moreComing: !remaining.isEmpty)
        }
    }

    /// The change log position macOS hasn't been told about, if any. Comparing with the log
    /// means nothing is lost to a crash or a failed signal: the next poll just asks again.
    public func pendingSignal() throws -> Int64? {
        let current = try currentAnchor().sequence
        let told = try database.execute("SELECT value FROM meta WHERE key = 'signalled'")
            .first?.text("value").flatMap(Int64.init) ?? 0
        return current > told ? current : nil
    }

    public func markSignalled(upTo sequence: Int64) throws {
        try database.execute(
            "INSERT OR REPLACE INTO meta(key, value) VALUES ('signalled', ?)", [.text(String(sequence))])
    }

    private func logChange(_ id: String, deleted: Bool, now: Date) throws {
        try database.execute(
            "INSERT INTO changes(item, deleted, created) VALUES (?, ?, ?)",
            [.text(id), .integer(deleted ? 1 : 0), .real(now.timeIntervalSince1970)])
    }

    /// Removes old change log entries and tombstones.
    public func prune(now: Date = Date()) throws {
        try database.transaction {
            let cutoff = now.addingTimeInterval(-Self.changeLogLifetime).timeIntervalSince1970
            let rows = try database.execute(
                "SELECT MAX(sequence) AS latest FROM changes WHERE created < ?", [.real(cutoff)])
            if let latest = rows.first?.integer("latest") {
                try database.execute("DELETE FROM changes WHERE sequence <= ?", [.integer(latest)])
                try database.execute(
                    "INSERT OR REPLACE INTO meta(key, value) VALUES ('pruned', ?)", [.text(String(latest))])
            }
            let tombstoneCutoff = now.addingTimeInterval(-Self.tombstoneLifetime).timeIntervalSince1970
            try database.execute(
                "DELETE FROM tombstones WHERE deleted_at < ?", [.real(tombstoneCutoff)])
        }
    }

    // MARK: Applying a listing

    /// Applies a successful folder listing in one transaction. Items absent from the
    /// listing aren't removed here: they're returned for a direct check, because absence
    /// from a listing is never enough to delete anything.
    @discardableResult
    public func apply(
        listing: [RemoteItem], in parentID: String, generation: Int64?, now: Date = Date()
    ) throws -> [SyncItem]? {
        try database.transaction {
            // A local change touched this folder while the listing ran, so it's stale.
            if let generation, let folder = try item(id: parentID), folder.generation != generation {
                return nil
            }

            // Keyed by exact bytes: Swift treats NFC and NFD forms as equal, and the server
            // and SQLite don't, so a String key could match the wrong item.
            var existing = Dictionary(
                try children(of: parentID).map { (Array($0.name.utf8), $0) },
                uniquingKeysWith: { first, _ in first })
            let doubted = try doubtedChildren(of: parentID)
            var seen = Set<[UInt8]>()
            var didAddOrRemove = false

            for entry in listing {
                let name = entry.path.name
                let version = entry.versionToken
                // A server listing the same name twice mustn't fail the whole folder.
                guard seen.insert(Array(name.utf8)).inserted else { continue }
                if let known = existing.removeValue(forKey: Array(name.utf8)) {
                    if known.kind != entry.kind {
                        // macOS can't change an item's type, so this is a delete and a create.
                        try removeTree(id: known.id, now: now, logging: true)
                        let id = UUID().uuidString
                        try insert(id: id, parentID: parentID, entry: entry, name: name)
                        try logChange(id, deleted: false, now: now)
                        didAddOrRemove = true
                        continue
                    }
                    // New details alone change no version, but macOS has to hear them to show them.
                    // An item macOS may have been told was gone has to be heard of again too.
                    let changed = known.version != version
                        || (entry.kind == .file && known.size != entry.size)
                        || !Self.sameDetails(known, entry)
                        || doubted.contains(known.id)
                    try database.execute(
                        """
                        UPDATE items SET size = ?, modified = ?, version = ?, versionID = ?,
                            own_modified = ?, created = ?, checksum = ?,
                            missing_passes = 0, missing_since = NULL WHERE id = ?
                        """,
                        [optional(entry.size), optional(entry.modified),
                         .text(version), optionalText(entry.versionID),
                         optional(entry.ownModified), optional(entry.created), optionalText(entry.checksum),
                         .text(known.id)])
                    if changed {
                        try logChange(known.id, deleted: false, now: now)
                    }
                } else if try !isTombstoned(parentID: parentID, name: name, version: version) {
                    let id = UUID().uuidString
                    try insert(id: id, parentID: parentID, entry: entry, name: name)
                    try logChange(id, deleted: false, now: now)
                    didAddOrRemove = true
                }
            }
            // Pages go by ID, so an item added before a page's place would be skipped, and a
            // page in progress has to be started again.
            if didAddOrRemove {
                try bumpGeneration(parentID)
            }
            try database.execute(
                "UPDATE items SET last_listed = ? WHERE id = ?",
                [.real(now.timeIntervalSince1970), .text(parentID)])
            return Array(existing.values).sorted { $0.name < $1.name }
        }
    }

    private func insert(id: String, parentID: String, entry: RemoteItem, name: String) throws {
        try database.execute(
            """
            INSERT INTO items(id, parent, name, kind, size, modified, version, versionID, own_modified, created, checksum)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [.text(id), .text(parentID), .text(name), .integer(entry.kind == .directory ? 1 : 0),
             optional(entry.size), optional(entry.modified), .text(entry.versionToken), optionalText(entry.versionID),
             optional(entry.ownModified), optional(entry.created), optionalText(entry.checksum)])
    }

    /// Whether a listing's details are what's already stored. Dates are compared as stored, to the
    /// microsecond, so a value that only went through the database doesn't count as new.
    private static func sameDetails(_ known: SyncItem, _ entry: RemoteItem) -> Bool {
        func stored(_ date: Date?) -> Int64? {
            date.map { Int64(($0.timeIntervalSince1970 * 1e6).rounded()) }
        }
        return stored(known.ownModified) == stored(entry.ownModified)
            && stored(known.created) == stored(entry.created)
            && known.checksum == entry.checksum
    }

    private func optional(_ value: Int64?) -> Database.Value {
        value.map(Database.Value.integer) ?? .null
    }

    private func optional(_ value: Date?) -> Database.Value {
        value.map { .real($0.timeIntervalSince1970) } ?? .null
    }

    private func optionalText(_ value: String?) -> Database.Value {
        value.map(Database.Value.text) ?? .null
    }

    private func isTombstoned(parentID: String, name: String, version: String) throws -> Bool {
        !(try database.execute(
            "SELECT 1 FROM tombstones WHERE parent = ? AND name = ? AND version = ?",
            [.text(parentID), .text(name), .text(version)]
        ).isEmpty)
    }

    // MARK: Missing items

    /// Records that a direct check said not-found, and returns how many passes have.
    public func recordMissingPass(id: String, now: Date = Date()) throws -> (passes: Int, since: Date) {
        try database.transaction {
            try database.execute(
                """
                UPDATE items SET missing_passes = missing_passes + 1,
                    missing_since = COALESCE(missing_since, ?) WHERE id = ?
                """,
                [.real(now.timeIntervalSince1970), .text(id)])
            let row = try database.execute(
                "SELECT missing_passes, missing_since FROM items WHERE id = ?", [.text(id)]).first
            return (
                Int(row?.integer("missing_passes") ?? 0),
                Date(timeIntervalSince1970: row?.real("missing_since") ?? now.timeIntervalSince1970))
        }
    }

    /// A direct check found the item. If it had been doubted, macOS may have been told it was gone,
    /// so it hears of it again.
    public func clearMissing(id: String, now: Date = Date()) throws {
        try database.transaction {
            let wasDoubted = try !database.execute(
                "SELECT 1 FROM items WHERE id = ? AND missing_passes > 0", [.text(id)]).isEmpty
            try database.execute(
                "UPDATE items SET missing_passes = 0, missing_since = NULL WHERE id = ?", [.text(id)])
            if wasDoubted {
                try logChange(id, deleted: false, now: now)
            }
        }
    }

    /// Items in a folder that a direct check, or macOS being told one was gone, left in doubt.
    private func doubtedChildren(of parentID: String) throws -> Set<String> {
        Set(try database.execute(
            "SELECT id FROM items WHERE parent = ? AND missing_passes > 0", [.text(parentID)]
        ).compactMap { $0.text("id") })
    }

    /// Removes an item the server has confirmed is gone, with everything inside it. The check
    /// ran over the network, so this only acts if the item is still exactly what was checked
    /// and nothing in it is being saved.
    /// - Parameter parentGeneration: The folder's generation when the listing started.
    /// - Returns: `false` if anything changed, and the item stays.
    @discardableResult
    public func removeConfirmed(
        _ observed: SyncItem, parentGeneration: Int64, now: Date = Date()
    ) throws -> Bool {
        try database.transaction {
            guard let current = try item(id: observed.id),
                  current.parentID == observed.parentID,
                  current.name == observed.name,
                  current.version == observed.version,
                  let parent = observed.parentID,
                  try item(id: parent)?.generation == parentGeneration
            else { return false }
            let tree = try treeIDs(id: observed.id)
            for id in tree where try hasOpenOperation(id: id, now: now) {
                return false
            }
            try removeTree(tree, now: now, logging: true)
            try bumpGeneration(parent)
            return true
        }
    }

    /// An item and everything inside it, deepest last. A loop can't trap this, because each
    /// item is only visited once.
    private func treeIDs(id: String) throws -> [String] {
        var ids = [id]
        var visited: Set<String> = [id]
        var next = 0
        while next < ids.count {
            for child in try children(of: ids[next]) where visited.insert(child.id).inserted {
                ids.append(child.id)
            }
            next += 1
        }
        return ids
    }

    private func removeTree(id: String, now: Date, logging: Bool) throws {
        try removeTree(try treeIDs(id: id), now: now, logging: logging)
    }

    private func removeTree(_ ids: [String], now: Date, logging: Bool) throws {
        for id in ids.reversed() {
            if logging {
                try logChange(id, deleted: true, now: now)
            }
            try database.execute("DELETE FROM items WHERE id = ?", [.text(id)])
        }
    }

    // MARK: Operations

    /// Records that a change to an item is going to the server. It's written first, so a
    /// listing can't remove the item while its save is in flight.
    @discardableResult
    public func beginOperation(item: String, kind: String, now: Date = Date()) throws -> String {
        let id = UUID().uuidString
        try database.transaction {
            // Only age proves a row's process died. Two can really run at once, and one starting
            // must not take away the other's protection.
            let cutoff = now.addingTimeInterval(-Self.operationLifetime).timeIntervalSince1970
            try database.execute("DELETE FROM operations WHERE started <= ?", [.real(cutoff)])
            try database.execute(
                "INSERT INTO operations(id, item, kind, started) VALUES (?, ?, ?, ?)",
                [.text(id), .text(item), .text(kind), .real(now.timeIntervalSince1970)])
        }
        return id
    }

    public func finishOperation(id: String) throws {
        try database.execute("DELETE FROM operations WHERE id = ?", [.text(id)])
    }

    private func hasOpenOperation(id: String, now: Date) throws -> Bool {
        let cutoff = now.addingTimeInterval(-Self.operationLifetime).timeIntervalSince1970
        return !(try database.execute(
            "SELECT 1 FROM operations WHERE item = ? AND started > ? LIMIT 1",
            [.text(id), .real(cutoff)]
        ).isEmpty)
    }

    // MARK: Local changes

    /// Records a local item that's now on the server. Local changes aren't echoed back
    /// through the change log, because macOS already knows about them.
    @discardableResult
    public func recordCreated(_ entry: RemoteItem, in parentID: String, now: Date = Date()) throws -> SyncItem {
        try database.transaction {
            let name = entry.path.name
            if let existing = try child(of: parentID, named: name) {
                try update(existing.id, with: entry)
            } else {
                try insert(id: UUID().uuidString, parentID: parentID, entry: entry, name: name)
            }
            try bumpGeneration(parentID)
            guard let saved = try child(of: parentID, named: name) else {
                throw missing(name)
            }
            return saved
        }
    }

    /// Puts back an item this Mac had removed, under the identifier macOS still has for it. Its
    /// removal is in the change log, so this goes there too, or macOS would act on the removal.
    @discardableResult
    public func recordRestored(
        id: String, entry: RemoteItem, in parentID: String, now: Date = Date()
    ) throws -> SyncItem {
        try database.transaction {
            let name = entry.path.name
            if let other = try child(of: parentID, named: name), other.id != id {
                // A listing found the file just saved, and took it for a new one.
                try removeTree(id: other.id, now: now, logging: true)
            }
            if try item(id: id) == nil {
                try insert(id: id, parentID: parentID, entry: entry, name: name)
            } else {
                try update(id, with: entry)
            }
            try logChange(id, deleted: false, now: now)
            try bumpGeneration(parentID)
            guard let saved = try item(id: id) else { throw missing(id) }
            return saved
        }
    }

    @discardableResult
    public func recordModified(id: String, entry: RemoteItem) throws -> SyncItem {
        try database.transaction {
            try update(id, with: entry)
            if let parent = try item(id: id)?.parentID {
                try bumpGeneration(parent)
            }
            guard let saved = try item(id: id) else { throw missing(id) }
            return saved
        }
    }

    private func update(_ id: String, with entry: RemoteItem) throws {
        try database.execute(
            """
            UPDATE items SET size = ?, modified = ?, version = ?, versionID = ?,
                own_modified = ?, created = ?, checksum = ?,
                missing_passes = 0, missing_since = NULL WHERE id = ?
            """,
            [optional(entry.size), optional(entry.modified), .text(entry.versionToken), optionalText(entry.versionID),
             optional(entry.ownModified), optional(entry.created), optionalText(entry.checksum), .text(id)])
    }

    /// Renames or moves an item. Its identity, and the identity of anything inside it, is kept.
    @discardableResult
    public func recordMoved(id: String, to parentID: String, name: String) throws -> SyncItem {
        try database.transaction {
            let oldParent = try item(id: id)?.parentID
            try database.execute(
                """
                UPDATE items SET parent = ?, name = ?, missing_passes = 0, missing_since = NULL
                WHERE id = ?
                """,
                [.text(parentID), .text(name), .text(id)])
            try bumpGeneration(parentID)
            if let oldParent, oldParent != parentID {
                try bumpGeneration(oldParent)
            }
            guard let saved = try item(id: id) else { throw missing(id) }
            return saved
        }
    }

    /// Records a local delete, and remembers that version so a stale listing can't bring it back.
    public func recordDeleted(id: String, now: Date = Date()) throws {
        try database.transaction {
            guard let existing = try item(id: id), let parent = existing.parentID else { return }
            try database.execute(
                "INSERT OR REPLACE INTO tombstones(parent, name, version, deleted_at) VALUES (?, ?, ?, ?)",
                [.text(parent), .text(existing.name), .text(existing.version), .real(now.timeIntervalSince1970)])
            try removeTree(id: id, now: now, logging: false)
            try bumpGeneration(parent)
        }
    }

    /// Forgets this Mac's own delete of whatever is at this path, because it was restored. A
    /// folder's version is always empty, and a move keeps a file's version on some servers, so the
    /// record of the delete would otherwise hide what came back.
    /// - Returns: The folder it's in, to be listed again, or nil if that folder isn't known here.
    @discardableResult
    public func forgetDeletion(at path: RemotePath) throws -> String? {
        guard let parentPath = path.parent else { return nil }
        var parentID = SyncItem.rootID
        for name in parentPath.components {
            guard let folder = try child(of: parentID, named: name), folder.kind == .directory else { return nil }
            parentID = folder.id
        }
        try database.execute(
            "DELETE FROM tombstones WHERE parent = ? AND name = ?", [.text(parentID), .text(path.name)])
        try bumpGeneration(parentID)
        return parentID
    }

    private func bumpGeneration(_ id: String) throws {
        try database.execute("UPDATE items SET generation = generation + 1 WHERE id = ?", [.text(id)])
    }

    // MARK: Local copies

    /// Notes that a file's content is on this device, after a download or a local change.
    public func markLocal(id: String, size: Int64, now: Date = Date()) throws {
        try database.execute(
            """
            INSERT INTO local_copies(id, size, last_used) VALUES (?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET size = excluded.size, last_used = excluded.last_used
            """,
            [.text(id), .integer(size), .real(now.timeIntervalSince1970)])
    }

    /// Notes when macOS says a file was last used, which is the best sign there is that someone
    /// still wants it. It only moves forward, so an old date can't make a fresh copy look idle.
    public func noteUsed(id: String, at date: Date) throws {
        try database.execute(
            "UPDATE local_copies SET last_used = MAX(last_used, ?) WHERE id = ?",
            [.real(date.timeIntervalSince1970), .text(id)])
    }

    /// The marks a person set on an item here, or nil if there are none.
    public func marks(id: String) throws -> ItemMarks? {
        guard let row = try database.execute(
            "SELECT last_used, tags, favorite_rank FROM marks WHERE id = ?", [.text(id)]).first
        else { return nil }
        return ItemMarks(
            lastUsed: row.real("last_used").map(Date.init(timeIntervalSince1970:)),
            tags: row.text("tags").flatMap { Data(base64Encoded: $0) },
            favoriteRank: row.integer("favorite_rank"))
    }

    /// Saves what a person set on an item here. Marks with nothing in them are removed.
    public func setMarks(_ marks: ItemMarks, id: String) throws {
        if marks.isEmpty {
            try database.execute("DELETE FROM marks WHERE id = ?", [.text(id)])
            return
        }
        try database.execute(
            """
            INSERT INTO marks(id, last_used, tags, favorite_rank) VALUES (?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                last_used = excluded.last_used, tags = excluded.tags, favorite_rank = excluded.favorite_rank
            """,
            [
                .text(id),
                marks.lastUsed.map { .real($0.timeIntervalSince1970) } ?? .null,
                marks.tags.map { .text($0.base64EncodedString()) } ?? .null,
                marks.favoriteRank.map { .integer($0) } ?? .null,
            ])
    }

    /// Forgets a local copy after an eviction, unless it was used again in the meantime.
    public func clearLocal(id: String, usedBefore date: Date = .distantFuture) throws {
        try database.execute(
            "DELETE FROM local_copies WHERE id = ? AND last_used < ?",
            [.text(id), .real(date.timeIntervalSince1970)])
    }

    /// The total size of local copies, for showing how much is cached.
    public func localCopiesSize() throws -> Int64 {
        try database.execute("SELECT COALESCE(SUM(size), 0) AS total FROM local_copies")
            .first?.integer("total") ?? 0
    }

    /// Brings the local-copies table in line with what macOS really has on disk, which also
    /// catches Remove Download and macOS's own evictions. Folders on disk count as in use:
    /// macOS only lists a folder once, so this is the only sign it still matters.
    /// - Parameter lastUsed: When macOS says each item was last used, for those it reports.
    public func reconcile(onDisk ids: Set<String>, lastUsed: [String: Date] = [:], now: Date = Date()) throws {
        try database.transaction {
            let recorded = Set(try database.execute("SELECT id FROM local_copies").compactMap { $0.text("id") })
            for id in recorded.subtracting(ids) {
                try database.execute("DELETE FROM local_copies WHERE id = ?", [.text(id)])
            }
            for id in ids {
                guard let found = try item(id: id) else { continue }
                if found.kind == .directory {
                    try markOpened(id: id, now: now)
                } else if !recorded.contains(id) {
                    try markLocal(id: id, size: max(0, found.size ?? 0), now: lastUsed[id] ?? now)
                } else if let used = lastUsed[id] {
                    try noteUsed(id: id, at: used)
                }
            }
        }
    }

    public func hasLocalCopy(id: String) throws -> Bool {
        !(try database.execute("SELECT 1 FROM local_copies WHERE id = ?", [.text(id)]).isEmpty)
    }

    // MARK: Offline

    private func flag(_ key: String) throws -> Bool {
        try database.execute("SELECT value FROM meta WHERE key = ?", [.text(key)]).first?.text("value") == "1"
    }

    private func setFlag(_ key: String, to value: Bool) throws {
        try database.execute(
            "INSERT OR REPLACE INTO meta(key, value) VALUES (?, ?)", [.text(key), .text(value ? "1" : "0")])
    }

    /// How long the app's word that a drive is offline lasts. It says so again on every poll, so
    /// an older mark means the app has stopped. The extension then finds out for itself, or
    /// uploads would wait until someone opened the app again.
    public static let offlineMarkLifetime: TimeInterval = 180

    /// How long a busy file waits before macOS is told to try again. A claim left by a crash lasts
    /// up to 10 minutes, and macOS's own back-off keeps growing long after that has gone.
    public static let busyRetryDelay: TimeInterval = 60

    /// Notes that a file couldn't be saved because its claim was busy. The earliest time is kept.
    public func noteBusyFile(now: Date = Date()) throws {
        try database.execute(
            "INSERT OR IGNORE INTO meta(key, value) VALUES ('busy_at', ?)",
            [.text(String(now.timeIntervalSince1970))])
    }

    /// Whether macOS should be told to try busy files again, which then counts as done.
    public func takeBusyRetry(now: Date = Date()) throws -> Bool {
        let noted = try database.execute("SELECT value FROM meta WHERE key = 'busy_at'")
            .first?.text("value").flatMap(Double.init)
        guard let noted, now.timeIntervalSince1970 - noted >= Self.busyRetryDelay else { return false }
        try database.execute("DELETE FROM meta WHERE key = 'busy_at'")
        return true
    }

    /// Whether the app has found the server unreachable. The extension reads this so it can
    /// answer at once, instead of leaving Finder waiting for a connection to time out.
    public func isOffline(now: Date = Date()) throws -> Bool {
        guard try flag("offline") else { return false }
        let marked = try database.execute("SELECT value FROM meta WHERE key = 'offline_at'")
            .first?.text("value").flatMap(Double.init)
        guard let marked else { return false }
        return now.timeIntervalSince1970 - marked < Self.offlineMarkLifetime
    }

    public func setOffline(_ isOffline: Bool, now: Date = Date()) throws {
        try setFlag("offline", to: isOffline)
        try database.execute(
            "INSERT OR REPLACE INTO meta(key, value) VALUES ('offline_at', ?)",
            [.text(String(now.timeIntervalSince1970))])
    }

    /// Rises each time a drive's sign-in or access changes. The extension keeps its connection for
    /// as long as it runs, so this is how it learns that connection is out of date.
    public func signInRevision() throws -> Int {
        try database.execute("SELECT value FROM meta WHERE key = 'signIn'").first?.text("value")
            .flatMap(Int.init) ?? 0
    }

    public func raiseSignInRevision() throws {
        try database.transaction {
            try database.execute(
                "INSERT OR REPLACE INTO meta(key, value) VALUES ('signIn', ?)",
                [.text(String(try signInRevision() + 1))])
        }
    }

    /// Whether this database was recovered, and macOS still has to be brought back in line.
    public func needsRebuild() throws -> Bool {
        try flag("rebuild")
    }

    public func setNeedsRebuild(_ needsRebuild: Bool) throws {
        try setFlag("rebuild", to: needsRebuild)
    }

    /// Finishes a recovery on a drive that only reads, such as the iPhone's. Nothing there is
    /// unsent, so nothing has to be matched up first: a new epoch has the system list everything
    /// again from scratch, and what it held under old identifiers goes with that. The Mac can't do
    /// this, because what macOS holds there may be the only copy of an edit.
    public func finishReadOnlyRecovery() throws {
        try database.transaction {
            try startNewEpoch()
            try setNeedsRebuild(false)
        }
    }

    /// How long macOS gets to finish an import before this stops waiting, in case it never says.
    /// A long wait costs nothing, because the only thing held back is calling an item gone.
    public static let importLimit: TimeInterval = 86_400

    /// Called before asking macOS to offer what it holds. It offers items one at a time, and until
    /// it's done, one can still go by an identifier from before the recovery.
    public func noteImportStarted(now: Date = Date()) throws {
        try database.execute(
            "INSERT OR REPLACE INTO meta(key, value) VALUES ('import_started', ?)",
            [.text(String(now.timeIntervalSince1970))])
    }

    public func noteImportFinished() throws {
        try database.execute("DELETE FROM meta WHERE key = 'import_started'")
    }

    /// Whether an item this database doesn't know might still exist. It might until the server
    /// has been walked and macOS says it has finished offering what it holds.
    public func isRecovering(now: Date = Date()) throws -> Bool {
        if try needsRebuild() { return true }
        let started = try database.execute("SELECT value FROM meta WHERE key = 'import_started'")
            .first?.text("value").flatMap(Double.init)
        guard let started else { return false }
        return now.timeIntervalSince1970 - started < Self.importLimit
    }

    /// What to say about an item that isn't here. Only a database that's known to be settled can
    /// say it's gone, so one that can't even tell has to say "try later".
    public func missing(_ id: String, now: Date = Date()) -> SyncError {
        do {
            return try isRecovering(now: now) ? .recovering : .itemNotFound(id)
        } catch {
            return .recovering
        }
    }

    /// Whether files that aren't on this device are shown as unavailable.
    public func showsUnavailable() throws -> Bool {
        try flag("unavailable")
    }

    /// Turns the unavailable badge on or off. macOS only looks at an item again when told to, so
    /// each file with no local copy goes through the change log. That's work for a big drive,
    /// which is why the app waits before doing this, and why it's capped.
    /// - Returns: Whether anything changed, so macOS needs telling.
    @discardableResult
    public func setShowsUnavailable(_ shows: Bool, limit: Int = 20_000, now: Date = Date()) throws -> Bool {
        try database.transaction {
            guard try flag("unavailable") != shows else { return false }
            try setFlag("unavailable", to: shows)
            let files = try database.execute(
                """
                SELECT id FROM items WHERE kind = 0 AND id NOT IN (SELECT id FROM local_copies)
                ORDER BY id LIMIT ?
                """,
                [.integer(Int64(limit))])
            for id in files.compactMap({ $0.text("id") }) {
                try logChange(id, deleted: false, now: now)
            }
            return true
        }
    }

    // MARK: Pinning

    /// Keeps a folder and everything added to it downloaded. The change goes through the log,
    /// so macOS picks up the new policy and fetches what's missing.
    public func setPinned(id: String, isPinned: Bool, now: Date = Date()) throws {
        try database.transaction {
            try database.execute(
                "UPDATE items SET pinned = ? WHERE id = ?", [.integer(isPinned ? 1 : 0), .text(id)])
            try logChange(id, deleted: false, now: now)
        }
    }

    private func isUnderPinnedFolder(_ id: String) throws -> Bool {
        var current: String? = id
        var steps = 0
        while let next = current, steps < Self.maximumDepth {
            guard let found = try item(id: next) else { return false }
            if found.isPinned { return true }
            current = found.parentID
            steps += 1
        }
        return false
    }

    // MARK: Failures

    /// Remembers a file that failed, for the menu. A later success clears it.
    public func recordFailure(id: String, name: String, message: String, now: Date = Date()) throws {
        try database.transaction {
            try writeFailure(id: id, name: name, message: message, now: now)
        }
    }

    private func writeFailure(id: String, name: String, message: String, now: Date) throws {
        let isNew = try !hasFailure(id: id)
        try database.execute(
            "INSERT OR REPLACE INTO failures(id, name, message, at) VALUES (?, ?, ?, ?)",
            [.text(id), .text(name), .text(message), .real(now.timeIntervalSince1970)])
        if isNew {
            try redrawBadge(of: id, now: now)
        }
    }

    public func clearFailure(id: String, now: Date = Date()) throws {
        try database.transaction {
            try database.execute("DELETE FROM attempts WHERE id = ?", [.text(id)])
            guard try hasFailure(id: id) else { return }
            try database.execute("DELETE FROM failures WHERE id = ?", [.text(id)])
            try redrawBadge(of: id, now: now)
        }
    }

    public func clearAllFailures(now: Date = Date()) throws {
        try database.transaction {
            let ids = try database.execute("SELECT id FROM failures").compactMap { $0.text("id") }
            try database.execute("DELETE FROM attempts")
            try database.execute("DELETE FROM failures")
            for id in ids {
                try redrawBadge(of: id, now: now)
            }
        }
    }

    public func hasFailure(id: String) throws -> Bool {
        !(try database.execute("SELECT 1 FROM failures WHERE id = ?", [.text(id)]).isEmpty)
    }

    // MARK: Files that keep failing

    /// How many failures, over how long, it takes to stop trying a file. macOS never gives up by
    /// itself, and each try can be a dozen requests.
    public static let attemptsBeforeHolding = 3
    public static let holdAfter: TimeInterval = 15 * 60

    private func attempt(from row: Database.Row) -> SyncAttempt? {
        guard let id = row.text("id"), let name = row.text("name"), let message = row.text("message"),
              let first = row.real("first_failed"), let last = row.real("last_failed"),
              let count = row.integer("count")
        else { return nil }
        return SyncAttempt(
            id: id, name: name, message: message,
            firstFailed: Date(timeIntervalSince1970: first), lastFailed: Date(timeIntervalSince1970: last),
            count: Int(count), isHeld: row.integer("held") == 1)
    }

    /// Counts a failure. Once a file has had enough chances and `canHold` allows it, it's held: it
    /// joins the failed list, and macOS's retries are answered without reaching the server.
    /// - Parameter canHold: False for something that clears by itself. It's shown, but never held.
    @discardableResult
    public func noteFailedAttempt(
        id: String, name: String, message: String, canHold: Bool, now: Date = Date()
    ) throws -> SyncAttempt {
        try database.transaction {
            let earlier = try database.execute("SELECT * FROM attempts WHERE id = ?", [.text(id)])
                .first.flatMap(attempt(from:))
            var noted = SyncAttempt(
                id: id, name: name, message: message, firstFailed: earlier?.firstFailed ?? now,
                lastFailed: now, count: (earlier?.count ?? 0) + 1, isHeld: earlier?.isHeld ?? false)
            if canHold, !noted.isHeld, noted.hasHadEnoughChances {
                noted.isHeld = true
                try writeFailure(
                    id: id, name: name, message: "Stopped trying after \(noted.count) failures. \(message)",
                    now: now)
                // A failure that blamed the server can leave macOS waiting on the whole drive.
                try noteBusyFile(now: now)
            }
            try database.execute(
                """
                INSERT OR REPLACE INTO attempts(id, name, message, first_failed, last_failed, count, held)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    .text(id), .text(name), .text(message), .real(noted.firstFailed.timeIntervalSince1970),
                    .real(now.timeIntervalSince1970), .integer(Int64(noted.count)),
                    .integer(noted.isHeld ? 1 : 0),
                ])
            return noted
        }
    }

    public func isHeld(id: String) throws -> Bool {
        !(try database.execute("SELECT 1 FROM attempts WHERE id = ? AND held = 1", [.text(id)]).isEmpty)
    }

    /// Answers macOS's retries for a held file, with no need for the server.
    public func checkNotHeld(id: String) throws {
        if try isHeld(id: id) {
            throw SyncError.held
        }
    }

    /// Where a failing file sits on the drive, or nil if its folder is no longer known.
    public func path(of attempt: SyncAttempt) -> RemotePath? {
        path(of: SyncFailure(
            id: attempt.id, name: attempt.name, message: attempt.message, date: attempt.lastFailed))
    }

    /// Files with a failure or an attempt on record that never reached the server. Nothing will
    /// ever report success for one that's been renamed, so these get checked for being gone.
    public func unsentFiles() throws -> [SyncFailure] {
        let failed = try failures()
        let known = Set(failed.map(\.id))
        let others = try attempts().filter { !known.contains($0.id) }.map {
            SyncFailure(id: $0.id, name: $0.name, message: $0.message, date: $0.lastFailed)
        }
        return (failed + others).filter(\.isUnsentFile)
    }

    public func attempt(id: String) throws -> SyncAttempt? {
        try database.execute("SELECT * FROM attempts WHERE id = ?", [.text(id)])
            .first.flatMap(attempt(from:))
    }

    public func attempts() throws -> [SyncAttempt] {
        try database.execute("SELECT * FROM attempts ORDER BY last_failed DESC LIMIT 500")
            .compactMap(attempt(from:))
    }

    // MARK: What's been done

    /// Enough to see what just happened, and small enough to read every second.
    public static let activityLimit = 200

    /// Notes something finished. The list is capped, and the totals go on counting.
    public func noteFinished(
        _ kind: SyncActivity.Kind, name: String, size: Int64?, now: Date = Date()
    ) throws {
        try database.transaction {
            try database.execute(
                "INSERT INTO activity(kind, name, size, at) VALUES (?, ?, ?, ?)",
                [.text(kind.rawValue), .text(name), size.map(Database.Value.integer) ?? .null,
                 .real(now.timeIntervalSince1970)])
            try database.execute(
                "DELETE FROM activity WHERE sequence <= (SELECT MAX(sequence) FROM activity) - ?",
                [.integer(Int64(Self.activityLimit))])
            try database.execute(
                "INSERT OR IGNORE INTO meta(key, value) VALUES ('totals_since', ?)",
                [.text(String(now.timeIntervalSince1970))])
            try database.execute(
                """
                INSERT INTO meta(key, value) VALUES (?, '1')
                ON CONFLICT(key) DO UPDATE SET value = CAST(value AS INTEGER) + 1
                """,
                [.text("total_\(kind.rawValue)")])
        }
    }

    public func recentActivity() throws -> [SyncActivity] {
        try database.execute(
            "SELECT * FROM activity ORDER BY sequence DESC LIMIT ?", [.integer(Int64(Self.activityLimit))]
        ).compactMap { row in
            guard let id = row.integer("sequence"), let kind = row.text("kind").flatMap(SyncActivity.Kind.init),
                  let name = row.text("name"), let date = row.real("at")
            else { return nil }
            return SyncActivity(
                id: id, kind: kind, name: name, size: row.integer("size"),
                date: Date(timeIntervalSince1970: date))
        }
    }

    public func totals() throws -> SyncTotals {
        let rows = try database.execute(
            "SELECT key, value FROM meta WHERE key LIKE 'total%'")
        var totals = SyncTotals()
        for row in rows {
            guard let key = row.text("key"), let value = row.text("value") else { continue }
            switch key {
            case "total_uploaded": totals.uploaded = Int(value) ?? 0
            case "total_downloaded": totals.downloaded = Int(value) ?? 0
            case "total_deleted": totals.deleted = Int(value) ?? 0
            case "totals_since": totals.since = Double(value).map(Date.init(timeIntervalSince1970:))
            default: break
            }
        }
        return totals
    }

    // MARK: Transfers

    /// A transfer that hasn't reported for this long isn't moving, whatever it says. It's longer
    /// than a commit takes, which sends no progress, and it's what stops a process that died
    /// from looking busy.
    public static let transferSilence: TimeInterval = 90

    /// Writes where a transfer has got to. A record that was cleared is put back, because a
    /// transfer can wait between engine calls for longer than a dead process's record is kept.
    public func recordTransfer(
        id: String, name: String, direction: SyncTransfer.Direction, done: Int64, total: Int64,
        started: Date, now: Date = Date()
    ) throws {
        try database.transaction {
            // Only a process that died leaves one of these behind.
            try database.execute(
                "DELETE FROM transfers WHERE updated < ?",
                [.real(now.timeIntervalSince1970 - Self.transferSilence)])
            try database.execute(
                """
                INSERT INTO transfers(id, name, direction, done, total, started, updated)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET done = excluded.done, updated = excluded.updated
                """,
                [.text(id), .text(name), .text(direction.rawValue), .integer(done), .integer(total),
                 .real(started.timeIntervalSince1970), .real(now.timeIntervalSince1970)])
        }
    }

    public func finishTransfer(id: String) throws {
        try database.execute("DELETE FROM transfers WHERE id = ?", [.text(id)])
    }

    /// What's moving right now. This is the proof behind any sign of progress.
    public func liveTransfers(now: Date = Date()) throws -> [SyncTransfer] {
        try database.execute(
            "SELECT * FROM transfers WHERE updated >= ? ORDER BY started",
            [.real(now.timeIntervalSince1970 - Self.transferSilence)]
        ).compactMap { row in
            guard let id = row.text("id"), let name = row.text("name"),
                  let direction = row.text("direction").flatMap(SyncTransfer.Direction.init),
                  let done = row.integer("done"), let total = row.integer("total"),
                  let started = row.real("started"), let updated = row.real("updated")
            else { return nil }
            return SyncTransfer(
                id: id, name: name, direction: direction, done: done, total: total,
                started: Date(timeIntervalSince1970: started), updated: Date(timeIntervalSince1970: updated))
        }
    }

    /// macOS only redraws a badge when it hears about the item. A new file that never got as far
    /// as being an item has no badge to redraw.
    private func redrawBadge(of id: String, now: Date) throws {
        if try item(id: id) != nil {
            try logChange(id, deleted: false, now: now)
        }
    }

    /// Where a failed file sits on the drive, or nil if its folder is no longer known.
    public func path(of failure: SyncFailure) -> RemotePath? {
        guard failure.isUnsentFile else { return try? path(of: failure.id) }
        return (try? path(of: failure.unsentParentID))?.appending(failure.name)
    }

    public func failures() throws -> [SyncFailure] {
        try database.execute("SELECT * FROM failures ORDER BY at DESC LIMIT 50").compactMap { row in
            guard let id = row.text("id"), let name = row.text("name"), let message = row.text("message"),
                  let date = row.real("at")
            else { return nil }
            return SyncFailure(id: id, name: name, message: message, date: Date(timeIntervalSince1970: date))
        }
    }

    /// Local copies to remove, oldest first: those idle for long enough, then enough more to
    /// fit the size limit. Idle means no download, no local change and no use that macOS has
    /// reported. Nil means that rule is off. Pinned folders are never touched.
    public func copiesToRemove(idleFor: TimeInterval?, sizeLimit: Int64?, now: Date = Date()) throws -> [String] {
        try database.execute("DELETE FROM local_copies WHERE id NOT IN (SELECT id FROM items)")
        let copies = try database.execute("SELECT * FROM local_copies ORDER BY last_used, id")
        // Sizes come from the server, so a forged one mustn't overflow and crash this.
        func sizeOf(_ row: Database.Row) -> Int64 { max(0, row.integer("size") ?? 0) }
        var total = copies.reduce(Int64(0)) { sum, copy in
            let (added, overflowed) = sum.addingReportingOverflow(sizeOf(copy))
            return overflowed ? .max : added
        }
        var chosen: [String] = []
        for copy in copies {
            guard let id = copy.text("id"), let lastUsed = copy.real("last_used") else { continue }
            if try isUnderPinnedFolder(id) { continue }
            if try item(id: id)?.isFlattenedPackage == true { continue }
            let isIdle = idleFor.map { now.timeIntervalSince1970 - lastUsed >= $0 } ?? false
            let isOverLimit = sizeLimit.map { total > $0 } ?? false
            if isIdle || isOverLimit {
                chosen.append(id)
                total -= min(total, sizeOf(copy))
            }
        }
        return chosen
    }

    /// Writes a consistent copy of the database, which holds the only map from item IDs to
    /// server paths.
    public func backUp(to url: URL) throws {
        // Written beside it and moved into place, so a full disk can't cost the last good backup.
        let partial = URL(fileURLWithPath: url.path + ".partial")
        try? FileManager.default.removeItem(at: partial)
        do {
            try database.execute("VACUUM INTO ?", [.text(partial.path)])
            guard rename(partial.path, url.path) == 0 else { throw SyncError.repairFailed }
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
    }

    /// Frees SQLite's cache, for when macOS is short of memory.
    public func releaseMemory() {
        database.releaseMemory()
    }

    // MARK: Polling

    public func markOpened(id: String, now: Date = Date()) throws {
        try database.execute(
            "UPDATE items SET last_opened = ? WHERE id = ?", [.real(now.timeIntervalSince1970), .text(id)])
    }

    /// Folders due a check. Folders never listed aren't included, because macOS asks for them
    /// when they're opened. The root is the exception: macOS mostly works from the working set
    /// and may never ask for it, so it's always checked at the recent interval.
    public func foldersDue(
        recentWithin: TimeInterval,
        recentInterval: TimeInterval,
        otherInterval: TimeInterval,
        limit: Int = 200,
        now: Date = Date()
    ) throws -> [SyncItem] {
        let time = now.timeIntervalSince1970
        return try database.execute(
            """
            SELECT * FROM items
            WHERE kind = 1 AND (
                (id = ? AND (last_listed IS NULL OR last_listed <= ?))
                OR (last_opened >= ? AND (last_listed IS NULL OR last_listed <= ?))
                OR last_listed <= ?)
            ORDER BY id = ? DESC, last_listed LIMIT ?
            """,
            [.text(SyncItem.rootID), .real(time - recentInterval),
             .real(time - recentWithin), .real(time - recentInterval), .real(time - otherInterval),
             .text(SyncItem.rootID), .integer(Int64(clamping: limit))]
        ).compactMap(item(from:))
    }
}
