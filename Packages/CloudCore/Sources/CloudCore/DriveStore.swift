// Apache 2 license - developer@infinitecontext.com

import Foundation
import Security

/// Saves connections in a shared folder and their secrets in the Keychain, so the app
/// and its extension see the same drives.
public struct DriveStore: Sendable {
    public enum StoreError: WordedError, Equatable {
        case keychain(OSStatus)
        case noSharedFolder
        /// A list of drives didn't read back whole after a move, so the old one was kept.
        case notMoved

        /// In the language shown.
        public var errorDescription: String? {
            wording.shown
        }

        public var englishDescription: String {
            wording.english
        }

        private var wording: Wording {
            switch self {
            case .keychain(let status) where status == errSecItemNotFound:
                Wording("This drive's password isn't in the Keychain.")
            case .keychain(let status):
                Wording("The Keychain couldn't be used (error %lld).", Int(status))
            case .noSharedFolder:
                Wording("The app's shared folder isn't available.")
            case .notMoved:
                Wording("The list of drives didn't move whole, so it was kept where it was.")
            }
        }
    }

    /// The identifiers the macOS app and its extension share.
    public static let appGroup = "group.com.infinitecontext.cloudaccess"
    public static let sharedKeychainGroup = "833T9Q2V4W.com.infinitecontext.CloudAccess"

    /// The identifiers the iPhone app and its Files extension share. On iOS an App Group is also a
    /// keychain group, and both targets have this one, so the extension reads the passwords
    /// without a Keychain Sharing entitlement of its own.
    public static let phoneAppGroup = "group.com.infinitecontext.CloudWanderer"
    public static let phoneKeychainGroup = phoneAppGroup
    /// The app's own group, where its passwords were before. The Files extension can't read it.
    public static let phoneEarlierKeychainGroup = "833T9Q2V4W.com.infinitecontext.CloudWanderer"

    /// The store the iPhone's Files extension reads, or nil in a build without the App Group.
    public static func phoneShared() -> DriveStore? {
        guard let directory = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: phoneAppGroup)
        else { return nil }
        return DriveStore(
            directory: directory, keychainGroup: phoneKeychainGroup,
            earlierKeychainGroup: phoneEarlierKeychainGroup, keepsPasswordsOnThisDevice: true)
    }

    /// The iPhone app's store. Its drives move into the shared folder when this build has one, so
    /// the Files extension can see them. Until a move has worked, the app keeps using its own
    /// folder and Files has nothing to show, which costs nothing but the Files locations.
    /// - Returns: The store to use, and whether it's the one the extension reads.
    public static func phone(ownFolder: URL, shared: DriveStore?) -> (store: DriveStore, isShared: Bool) {
        let own = DriveStore(directory: ownFolder, keepsPasswordsOnThisDevice: true)
        guard let shared else { return (own, false) }
        do {
            try shared.adoptConnections(from: own)
            return (shared, true)
        } catch {
            return (own, false)
        }
    }

    /// Takes over the drives another store lists. The old list goes only once this one reads back
    /// with every drive in it, so a move that fails leaves the drives where they were. A drive both
    /// lists hold keeps this store's copy, which is the newer one. Passwords move separately, in
    /// `movePasswordsHere()`.
    public func adoptConnections(from old: DriveStore) throws {
        guard old.file != file, FileManager.default.fileExists(atPath: old.file.path) else { return }
        let earlier = try old.connections()
        var all = try connections()
        for connection in earlier where !all.contains(where: { $0.id == connection.id }) {
            all.append(connection)
        }
        try write(all)
        let written = Set(try connections().map(\.id))
        guard earlier.allSatisfy({ written.contains($0.id) }) else { throw StoreError.notMoved }
        try FileManager.default.removeItem(at: old.file)
    }

    private let file: URL
    private let keychainGroup: String?
    private let earlierKeychainGroup: String?
    private let keepsPasswordsOnThisDevice: Bool

    private static let service = "CloudAccess"

    /// - Parameters:
    ///   - directory: Where the list of connections is kept.
    ///   - keychainGroup: The access group shared with the extension, if any.
    ///   - earlierKeychainGroup: Where passwords were kept before, read when one hasn't moved yet.
    ///   - keepsPasswordsOnThisDevice: Passwords never leave this device, even in an encrypted
    ///     backup. The iPhone's owner chose this; the Mac keeps passwords in its backups.
    public init(
        directory: URL, keychainGroup: String? = nil, earlierKeychainGroup: String? = nil,
        keepsPasswordsOnThisDevice: Bool = false
    ) {
        file = directory.appendingPathComponent("connections.json")
        self.keychainGroup = keychainGroup
        self.earlierKeychainGroup = earlierKeychainGroup
        self.keepsPasswordsOnThisDevice = keepsPasswordsOnThisDevice
    }

    /// The store shared by the macOS app and its extension.
    public static func shared() throws -> DriveStore {
        guard let directory = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup)
        else { throw StoreError.noSharedFolder }
        return DriveStore(directory: directory, keychainGroup: sharedKeychainGroup)
    }

    /// Where the iPhone's Files extension leaves its memory measurements.
    public var memoryReportURL: URL {
        file.deletingLastPathComponent().appendingPathComponent("files-extension-memory.json")
    }

    /// Where the iPhone's Files extension leaves what a person needs to know about a drive.
    public func filesNotesURL(for id: UUID) -> URL {
        file.deletingLastPathComponent()
            .appendingPathComponent("FilesNotes")
            .appendingPathComponent("\(id.uuidString).json")
    }

    /// A stable ID for this device, created on first use.
    public func deviceID() throws -> String {
        let idFile = file.deletingLastPathComponent().appendingPathComponent("device-id")
        if let saved = try? String(contentsOf: idFile, encoding: .utf8), !saved.isEmpty {
            return saved
        }
        let created = UUID().uuidString
        try created.write(to: idFile, atomically: true, encoding: .utf8)
        return created
    }

    /// Where a drive's state database lives.
    public func databaseURL(for id: UUID) throws -> URL {
        let folder = file.deletingLastPathComponent().appendingPathComponent("Drives")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("\(id.uuidString).sqlite")
    }

    /// The log shared by the app and its extension. It's in a folder of its own, because a person
    /// can open it in Finder, and what's beside it here shouldn't be touched.
    public var diagnostics: Diagnostics {
        let shared = file.deletingLastPathComponent()
        return Diagnostics(directory: shared.appendingPathComponent("Logs"), earlierDirectory: shared)
    }

    /// Deletes a drive's state once macOS has removed it.
    public func deleteDatabase(for id: UUID) throws {
        let database = try databaseURL(for: id)
        for suffix in ["", "-wal", "-shm", ".damaged", ".damaged-wal", ".damaged-shm", ".known", ".lock"] {
            try? FileManager.default.removeItem(atPath: database.path + suffix)
        }
        let stem = database.deletingPathExtension()
        for copy in ["backup", "before-upgrade"] {
            try? FileManager.default.removeItem(at: stem.appendingPathExtension(copy))
        }
    }

    /// A drive's backup, kept beside its database.
    public func backupURL(for id: UUID) throws -> URL {
        try databaseURL(for: id).deletingPathExtension().appendingPathExtension("backup")
    }

    // MARK: Preserved files

    /// Files macOS kept when a drive with unsent changes was removed.
    public struct PreservedFiles: Codable, Identifiable, Sendable, Hashable {
        public var id = UUID()
        public var driveName: String
        public var path: String
        public var date: Date

        public init(driveName: String, path: String, date: Date = Date()) {
            self.driveName = driveName
            self.path = path
            self.date = date
        }
    }

    private var preservedFile: URL {
        file.deletingLastPathComponent().appendingPathComponent("preserved.json")
    }

    public func preservedFiles() throws -> [PreservedFiles] {
        guard FileManager.default.fileExists(atPath: preservedFile.path) else { return [] }
        return try JSONDecoder().decode([PreservedFiles].self, from: Data(contentsOf: preservedFile))
    }

    public func addPreserved(_ files: PreservedFiles) throws {
        let all = try preservedFiles() + [files]
        try JSONEncoder().encode(all).write(to: preservedFile, options: .atomic)
    }

    public func removePreserved(id: UUID) throws {
        let all = try preservedFiles().filter { $0.id != id }
        try JSONEncoder().encode(all).write(to: preservedFile, options: .atomic)
    }

    // MARK: Connections

    public func connections() throws -> [Connection] {
        try savedConnections() ?? []
    }

    /// The saved drives, or nil if no list has been saved here at all. Anything that deletes on
    /// the strength of a drive being absent needs this: a missing list says nothing about a drive.
    public func savedConnections() throws -> [Connection]? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try JSONDecoder().decode([Connection].self, from: Data(contentsOf: file))
    }

    public func connection(id: UUID) throws -> Connection? {
        try connections().first { $0.id == id }
    }

    public func save(_ connection: Connection) throws {
        var all = try connections()
        if let index = all.firstIndex(where: { $0.id == connection.id }) {
            all[index] = connection
        } else {
            all.append(connection)
        }
        try write(all)
    }

    public func remove(id: UUID) throws {
        try write(connections().filter { $0.id != id })
        try deleteCredentials(for: id)
        if let earlierKeychainGroup {
            _ = SecItemDelete(query(for: id, in: earlierKeychainGroup) as CFDictionary)
        }
    }

    private func write(_ connections: [Connection]) throws {
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(connections).write(to: file, options: .atomic)
    }

    // MARK: Credentials

    private func query(for id: UUID) -> [CFString: Any] {
        query(for: id, in: keychainGroup)
    }

    private func query(for id: UUID, in group: String?) -> [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecAttrAccount: id.uuidString,
            kSecUseDataProtectionKeychain: true,
        ]
        if let group {
            query[kSecAttrAccessGroup] = group
        }
        return query
    }

    /// A saved password's bytes, and the status of the read.
    private func read(_ id: UUID, in group: String?) -> (data: Data?, status: OSStatus) {
        var search = query(for: id, in: group)
        search[kSecReturnData] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(search as CFDictionary, &result)
        return (status == errSecSuccess ? result as? Data : nil, status)
    }

    private func lookup(_ id: UUID, in group: String?) -> PasswordMove.Lookup {
        let (data, status) = read(id, in: group)
        if let data { return .found(data) }
        return status == errSecItemNotFound ? .missing : .failed
    }

    private func saveData(_ data: Data, for id: UUID) -> OSStatus {
        let attributes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: accessibility,
        ]
        var status = SecItemUpdate(query(for: id) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let item = query(for: id).merging(attributes) { _, new in new }
            status = SecItemAdd(item as CFDictionary, nil)
        }
        return status
    }

    /// Readable after first unlock, so the extension keeps working while locked.
    private var accessibility: CFString {
        keepsPasswordsOnThisDevice ? kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly : kSecAttrAccessibleAfterFirstUnlock
    }

    public func save(_ credentials: Credentials, for id: UUID) throws {
        let status = saveData(try JSONEncoder().encode(credentials), for: id)
        guard status == errSecSuccess else { throw StoreError.keychain(status) }
    }

    /// Moves every password this store saved earlier onto "this device only", in one update per
    /// group. Running it again changes nothing. On a store that keeps passwords in backups, it
    /// does nothing.
    public func keepSavedPasswordsOnThisDevice() {
        guard keepsPasswordsOnThisDevice else { return }
        let groups: [String?] = earlierKeychainGroup.map { [keychainGroup, $0] } ?? [keychainGroup]
        for group in groups {
            var search: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: Self.service,
                kSecUseDataProtectionKeychain: true,
            ]
            if let group {
                search[kSecAttrAccessGroup] = group
            }
            let change: [CFString: Any] = [kSecAttrAccessible: accessibility]
            _ = SecItemUpdate(search as CFDictionary, change as CFDictionary)
        }
    }

    /// Moves each drive's password from where it was kept before to where this store keeps them,
    /// such as where the iPhone's Files extension can read them. Only the app runs this: the
    /// extension can't read the earlier place. Running it again changes nothing.
    @discardableResult
    public func movePasswordsHere() -> [UUID: PasswordMove.Outcome] {
        guard let earlierKeychainGroup, earlierKeychainGroup != keychainGroup else { return [:] }
        var outcomes: [UUID: PasswordMove.Outcome] = [:]
        for id in (try? connections().map(\.id)) ?? [] {
            outcomes[id] = PasswordMove.run(
                readNew: { lookup(id, in: keychainGroup) },
                readOld: { lookup(id, in: earlierKeychainGroup) },
                saveNew: { saveData($0, for: id) == errSecSuccess },
                deleteNew: { _ = SecItemDelete(query(for: id) as CFDictionary) },
                deleteOld: { _ = SecItemDelete(query(for: id, in: earlierKeychainGroup) as CFDictionary) })
        }
        return outcomes
    }

    /// A password that hasn't moved yet is read where it was, so the app never loses one whose
    /// move failed. The Files extension can't read there, and gets the first answer.
    public func credentials(for id: UUID) throws -> Credentials {
        var (data, status) = read(id, in: keychainGroup)
        if data == nil, status == errSecItemNotFound, let earlierKeychainGroup {
            data = read(id, in: earlierKeychainGroup).data
        }
        guard let data else { throw StoreError.keychain(status) }
        return try JSONDecoder().decode(Credentials.self, from: data)
    }

    private func deleteCredentials(for id: UUID) throws {
        let status = SecItemDelete(query(for: id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw StoreError.keychain(status)
        }
    }
}
