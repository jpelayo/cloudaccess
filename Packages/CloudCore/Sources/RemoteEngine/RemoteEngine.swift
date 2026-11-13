// Apache 2 license - developer@infinitecontext.com

import CEngine
import CloudCore
import Foundation
import Synchronization

/// Serves a drive through the Go engine, which wraps rclone.
public final class RemoteEngine: RemoteBackend {
    /// What to pin after a first success on an encrypted drive.
    public struct VaultPin: Sendable, Equatable {
        public let id: String
        public let revision: Int
    }

    /// An SFTP server's identity, shown to a person before it's trusted.
    public struct HostKey: Sendable, Equatable, Decodable {
        public let key: String
        public let fingerprint: String
    }

    private let driveID: String

    /// The vault this drive opened, for an encrypted drive.
    public let vault: VaultPin?

    private static let nextCallID = Atomic<Int64>(1)

    /// Engine calls block, so they run here rather than on Swift's cooperative thread pool.
    private static let queue = DispatchQueue(
        label: "cloudaccess.engine", qos: .userInitiated, attributes: .concurrent)

    /// A soft limit on Go's own memory, so its heap doesn't grow unchecked between collections.
    private static let setUp: Void = {
        if isLean.load(ordering: .acquiring) {
            CMInitLean(Int64(leanMemoryLimit), Int64(leanFolderLimit))
        } else {
            CMInit(256 << 20)
        }
    }()

    private static let isLean = Atomic<Bool>(false)

    /// Go's soft limit in a lean process. Lower would have it collecting all the time.
    public static let leanMemoryLimit = 8 << 20

    /// The largest folder a lean process lists. A bigger one is refused whole. Set from what the
    /// iPhone's Files extension was measured to hold.
    public static let leanFolderLimit = 5_000

    /// Prepares the engine for a process iOS stops at a small size, such as the iPhone's Files
    /// extension: one transfer at a time, a cap on folder size, and memory handed back after each
    /// call. Call it before anything else here, or it does nothing.
    public static func useLean() {
        isLean.store(true, ordering: .releasing)
        _ = setUp
    }

    /// Whether this process runs the engine lean.
    public static var runsLean: Bool {
        _ = setUp
        return isLean.load(ordering: .acquiring)
    }

    /// A drive's background transfers share its gate. Files a person opens use their own, so a
    /// busy queue of uploads can't stand between someone and the document they just opened.
    private let backgroundTransfers: TransferGate
    private static let userTransfers = TransferGate(limit: runsLean ? 1 : 2)
    /// Opening runs scrypt, which is memory-heavy, so drives open one at a time.
    private static let opens = TransferGate(limit: 1)
    /// iOS may serve several drives from one Files extension, and its memory limit is for the
    /// whole process, so a lean process has one background transfer for all of them.
    private static let leanBackgroundTransfers = TransferGate(limit: 1)
    /// A call waiting inside the engine holds a thread the whole time, and each thread costs a lean
    /// process memory. So lookups and listings wait here instead, two at a time.
    private static let leanLookups: TransferGate? = runsLean ? TransferGate(limit: 2) : nil

    private static func withLookup<Result: Sendable>(_ body: () async throws -> Result) async throws -> Result {
        guard let gate = leanLookups else { return try await body() }
        try await gate.acquire()
        do {
            let result = try await body()
            await gate.release()
            return result
        } catch {
            await gate.release()
            throw error
        }
    }

    private func withTransfer<Result: Sendable>(
        _ body: () async throws -> Result
    ) async throws -> Result {
        let gate = TransferContext.isUserRequest ? Self.userTransfers : backgroundTransfers
        try await gate.acquire()
        do {
            let result = try await body()
            await gate.release()
            return result
        } catch {
            await gate.release()
            throw error
        }
    }

    /// Connects to a drive. On an encrypted drive this verifies the vault first, so a
    /// wrong password throws `RemoteError.vault` instead of showing an empty folder.
    /// - Parameters:
    ///   - createVault: Allows creating a vault in an empty folder.
    ///   - device: Who's saving, for staging files and conflict copy names.
    public init(
        connection: Connection,
        credentials: Credentials,
        createVault: Bool = false,
        device: DeviceInfo? = nil
    ) async throws {
        _ = Self.setUp
        // Each engine has its own handle. Closing one must never close another that's serving
        // the same drive, which is what happens when two requests connect at the same moment.
        driveID = UUID().uuidString
        backgroundTransfers = Self.runsLean
            ? Self.leanBackgroundTransfers : TransferGate(limit: max(1, connection.settings.uploadsAtOnce))
        let configuration = DriveConfiguration(
            id: driveID, connection: connection, credentials: credentials,
            createVault: createVault, device: device)
        try await Self.opens.acquire()
        let opening: Result<OpenResult, Error>
        do {
            opening = .success(try await Self.call("open", configuration, path: .root))
        } catch {
            opening = .failure(error)
        }
        await Self.opens.release()
        let opened = try opening.get()
        if let id = opened.vaultID, let revision = opened.revision {
            vault = VaultPin(id: id, revision: revision)
        } else {
            vault = nil
        }
    }

    deinit {
        let arguments = Self.encode(Arguments(drive: driveID))
        // Closes get their own IDs too: sharing one is how two closes once crashed the engine.
        let callID = Self.nextCallID.add(1, ordering: .relaxed).newValue
        Self.queue.async {
            _ = Self.invoke(callID, "close", arguments)
        }
    }

    /// Reads a server's key without signing in, so it can be confirmed before it's pinned.
    public static func hostKey(host: String, port: Int) async throws -> HostKey {
        _ = setUp
        return try await call("hostKey", HostKeyRequest(host: host, port: port), path: .root)
    }

    /// Describes a key that's already saved, for comparing with what a server offers now.
    public static func hostKeyDetails(key: String) async throws -> HostKey {
        _ = setUp
        return try await call("hostKeyFingerprint", SavedKey(key: key), path: .root)
    }

    /// Gives unused memory back to macOS, for when it's running short.
    public static func releaseMemory() async {
        _ = setUp
        let _: Empty? = try? await call("trim", Arguments(drive: ""), path: .root)
    }

    // MARK: RemoteBackend

    public func checkHealth() async throws {
        let _: Empty = try await Self.call("health", Arguments(drive: driveID), path: .root)
    }

    public func reportsVersions() async throws -> Bool {
        let result: ProbeResult = try await Self.call("probe", Arguments(drive: driveID), path: .root)
        return result.versions
    }

    public func item(at path: RemotePath) async throws -> RemoteItem {
        let values = arguments(path: path)
        let item: EngineItem = try await Self.withLookup {
            try await Self.call("stat", values, path: path)
        }
        return item.remoteItem(at: path)
    }

    public func list(_ path: RemotePath) async throws -> [RemoteItem] {
        let values = arguments(path: path)
        let items: [EngineItem] = try await Self.withLookup {
            try await Self.call("list", values, path: path)
        }
        return items.compactMap { item in
            RemotePath(item.path).map { item.remoteItem(at: $0) }
        }
    }

    public func download(_ path: RemotePath, to destination: URL) async throws {
        try await download(path, to: destination, checksum: nil)
    }

    public func download(_ path: RemotePath, to destination: URL, checksum: String?) async throws {
        var values = arguments(path: path, destination: destination.path)
        values.sha256 = checksum
        let finished = values
        let _: Empty = try await withTransfer {
            try await Self.call("download", finished, path: path)
        }
    }

    public func read(
        _ path: RemotePath, offset: Int64, length: Int64, to destination: URL
    ) async throws {
        var values = arguments(path: path, destination: destination.path)
        values.offset = offset
        values.length = length
        let finished = values
        let _: Empty = try await withTransfer {
            try await Self.call("read", finished, path: path)
        }
    }

    @discardableResult
    public func upload(from source: URL, to path: RemotePath) async throws -> RemoteItem {
        var values = arguments(path: path)
        values.source = source.path
        let item: EngineItem = try await Self.call("upload", values, path: path)
        return item.remoteItem(at: path)
    }

    public func stage(from source: URL) async throws -> StagedUpload {
        var values = Arguments(drive: driveID)
        values.source = source.path
        let finished = values
        let result: EngineStage = try await withTransfer {
            try await Self.call("stage", finished, path: .root)
        }
        return StagedUpload(token: result.staged)
    }

    public func checkName(_ path: RemotePath) async throws {
        let _: Empty = try await Self.call("checkName", arguments(path: path), path: path)
    }

    public func discard(_ staged: StagedUpload) async {
        var values = Arguments(drive: driveID)
        values.staged = staged.token
        let _: Empty? = try? await Self.call("discardStage", values, path: .root)
    }

    @discardableResult
    public func commit(
        _ staged: StagedUpload, source: URL, to path: RemotePath, baseVersion: String?, failOnConflict: Bool
    ) async throws -> SaveResult {
        try await commit(
            staged, source: source, to: path, baseVersion: baseVersion, failOnConflict: failOnConflict,
            details: FileDetails())
    }

    @discardableResult
    public func commit(
        _ staged: StagedUpload, source: URL, to path: RemotePath, baseVersion: String?, failOnConflict: Bool,
        details: FileDetails
    ) async throws -> SaveResult {
        var values = arguments(path: path)
        values.source = source.path
        values.staged = staged.token
        values.baseVersion = baseVersion
        values.failOnConflict = failOnConflict
        values.modifiedNs = details.modified.map(Self.nanoseconds)
        values.createdNs = details.created.map(Self.nanoseconds)
        values.bundleType = details.bundleType
        let result: EngineSave = try await Self.call("commit", values, path: path)
        return SaveResult(
            item: result.item.remoteItem(at: path),
            conflictCopy: result.conflictPath.flatMap(RemotePath.init),
            detailsMissed: result.detailsMissed)
    }

    public func createDirectory(_ path: RemotePath) async throws {
        try await createDirectory(path, created: nil)
    }

    public func createDirectory(_ path: RemotePath, created: Date?) async throws {
        var values = arguments(path: path)
        values.createdNs = created.map(Self.nanoseconds)
        let _: Empty = try await Self.call("mkdir", values, path: path)
    }

    private static func nanoseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1e9).rounded())
    }

    @discardableResult
    public func move(
        from source: RemotePath, to destination: RemotePath, baseVersion: String?
    ) async throws -> RemoteItem {
        var values = Arguments(drive: driveID)
        values.source = source.description
        values.destination = destination.description
        values.baseVersion = baseVersion
        let item: EngineItem = try await Self.call("move", values, path: source)
        return item.remoteItem(at: destination)
    }

    public func delete(_ path: RemotePath) async throws {
        let _: Empty = try await Self.call("delete", arguments(path: path), path: path)
    }

    public func trash(_ path: RemotePath, baseVersion: String?) async throws {
        var values = arguments(path: path)
        values.baseVersion = baseVersion
        let _: Empty = try await Self.call("trash", values, path: path)
    }

    // MARK: Drive upkeep

    /// A deleted item that can still be restored.
    public struct TrashEntry: Sendable, Decodable, Identifiable, Hashable {
        public let id: String
        public let originalPath: String
        public let deletedAt: Int64
        public let device: String
        public let isDirectory: Bool
        /// Its details can't be trusted, so it can't be restored. It's purged by age, or deleted
        /// by hand.
        public let isDamaged: Bool
        /// A save replaced this, so the file itself is still on the drive.
        public let isVersion: Bool
    }

    /// What a recovery kit needs from the vault.
    public struct VaultDetails: Sendable, Decodable {
        public let vaultID: String
        public let salt: String
    }

    private struct PolicyResult: Decodable, Sendable {
        var trashRetentionSeconds: Int
    }

    private struct MaintenanceResult: Decodable, Sendable, ValueOptional {
        var purgedEntries: Int?
        var sweptFiles: Int?
        var purgeSkipped: String?
        var retentionSeconds: Int?

        init() {}
    }

    /// What a maintenance pass found.
    public struct Maintenance: Sendable {
        /// Why no trash was purged, if the retention policy couldn't be trusted.
        public let purgeSkipped: String?
        /// How long the drive keeps what's deleted, if that could be read.
        public let retentionSeconds: Int?
    }

    public func trashEntries() async throws -> [TrashEntry] {
        try await Self.call("trashList", Arguments(drive: driveID), path: .root)
    }

    /// - Returns: Where it went back, which can be another name if its own was taken.
    @discardableResult
    public func restoreFromTrash(_ id: String) async throws -> RemotePath? {
        var values = Arguments(drive: driveID)
        values.path = id
        let restored: EngineItem = try await Self.call("trashRestore", values, path: .root)
        return RemotePath(restored.path)
    }

    /// Removes one entry from the trash for good, now, because a person chose it. One already gone
    /// counts as done.
    public func purgeFromTrash(_ id: String) async throws {
        var values = Arguments(drive: driveID)
        values.path = id
        let _: Empty = try await Self.call("trashPurge", values, path: .root)
    }

    /// Clears what's past its time: old trash, abandoned uploads, and crashed claims.
    @discardableResult
    public func maintain() async throws -> Maintenance {
        let result: MaintenanceResult = try await Self.call("maintain", Arguments(drive: driveID), path: .root)
        return Maintenance(purgeSkipped: result.purgeSkipped, retentionSeconds: result.retentionSeconds)
    }

    public func trashRetentionSeconds() async throws -> Int {
        let policy: PolicyResult = try await Self.call("getPolicy", Arguments(drive: driveID), path: .root)
        return policy.trashRetentionSeconds
    }

    /// Shared by every device on the drive.
    public func setTrashRetention(seconds: Int) async throws {
        var values = Arguments(drive: driveID)
        values.length = Int64(seconds)
        let _: Empty = try await Self.call("setPolicy", values, path: .root)
    }

    /// What the hidden `.cloudmount` folder holds, so a person can decide whether to remove it.
    public struct ControlFolder: Sendable, Decodable, Equatable {
        public let exists: Bool
        /// An encrypted drive's marker. It always stays: the drive can't be opened without it.
        public let hasVault: Bool
        /// Deleted files and replaced versions that would be gone for good.
        public let trashItems: Int
        /// Other devices that have saved here in Safe mode, and will make the folder again.
        public let safeDevices: Int
        /// A device in Safe mode looks to be saving right now.
        public let busy: Bool
        public let removed: Bool
        /// What's there besides the vault: trash, uploads, locks and shared settings.
        public let otherEntries: Int

        /// Whether a clean-up would remove anything.
        public var hasRemovable: Bool { otherEntries > 0 }
    }

    public func controlFolder() async throws -> ControlFolder {
        try await Self.call("controlFolder", Arguments(drive: driveID), path: .root)
    }

    /// Removes the control folder, keeping an encrypted drive's vault. Only a connection in Unsafe
    /// mode can, and it refuses while a device in Safe mode is saving.
    @discardableResult
    public func cleanControlFolder() async throws -> ControlFolder {
        try await Self.call("cleanControlFolder", Arguments(drive: driveID), path: .root)
    }

    /// Stops every device writing to this vault once it next checks.
    public func retireVault() async throws {
        let _: Empty = try await Self.call("retireVault", Arguments(drive: driveID), path: .root)
    }

    public func vaultDetails() async throws -> VaultDetails {
        try await Self.call("vaultDetails", Arguments(drive: driveID), path: .root)
    }

    private struct SeenRevision: Decodable {
        let revision: Int
    }

    /// The highest vault revision this connection has seen, which needs no server.
    public func seenVaultRevision() async throws -> Int {
        let seen: SeenRevision = try await Self.call("vaultRevision", Arguments(drive: driveID), path: .root)
        return seen.revision
    }

    // MARK: Engine calls

    private func arguments(path: RemotePath, destination: String? = nil) -> Arguments {
        var values = Arguments(drive: driveID)
        values.path = path.description
        values.destination = destination
        return values
    }

    private static func encode<Value: Encodable>(_ value: Value) -> String {
        // These types only hold strings and numbers, so encoding can't fail.
        String(decoding: (try? JSONEncoder().encode(value)) ?? Data("{}".utf8), as: UTF8.self)
    }

    /// Makes the blocking C call. cgo declares its strings as mutable, but never writes to them.
    /// The engine's bytes become the result as they are, with no copy, and go back to the engine
    /// to be freed once decoded. A big listing would otherwise be in memory several times at once.
    private static func invoke(_ callID: Int64, _ method: String, _ arguments: String) -> Data {
        method.withCString { methodPointer in
            arguments.withCString { argumentsPointer in
                var length: Int64 = 0
                guard let result = CMCallBytes(
                    callID,
                    UnsafeMutablePointer(mutating: methodPointer),
                    UnsafeMutablePointer(mutating: argumentsPointer),
                    &length)
                else { return Data() }
                return Data(bytesNoCopy: result, count: Int(length), deallocator: .custom { pointer, _ in
                    CMFree(pointer.assumingMemoryBound(to: CChar.self))
                })
            }
        }
    }

    private static func call<Input: Encodable, Output: Decodable & Sendable>(
        _ method: String, _ input: Input, path: RemotePath
    ) async throws -> Output {
        let callID = nextCallID.add(1, ordering: .relaxed).newValue
        let arguments = encode(input)

        // Registered first, so a cancel arriving at any later moment isn't lost.
        CMRegister(callID)

        // Reports bytes while a transfer runs, for whoever asked to hear them.
        let reporter = TransferContext.progress.map { report in
            Task.detached {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(500))
                    let bytes = CMProgress(callID)
                    if bytes >= 0 { report(Int64(bytes)) }
                }
            }
        }
        defer { reporter?.cancel() }

        let response: Data = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async {
                    continuation.resume(returning: invoke(callID, method, arguments))
                }
            }
        } onCancel: {
            CMCancel(callID)
        }

        let decoded: CallResult<Output>
        do {
            decoded = try JSONDecoder().decode(CallResult<Output>.self, from: response)
        } catch {
            throw RemoteError.failed(path, "The engine returned an unreadable response.")
        }
        if let failure = decoded.error {
            throw failure.remoteError(at: path)
        }
        if let value = decoded.value {
            return value
        }
        if let type = Output.self as? any ValueOptional.Type, let empty = type.init() as? Output {
            return empty
        }
        throw RemoteError.failed(path, "The engine returned no result.")
    }
}

// MARK: Wire format

/// What the current task is transferring for, carried down to the engine call.
public enum TransferContext {
    /// A person is waiting on this, so it skips the background queue.
    @TaskLocal public static var isUserRequest = false
    /// Hears the bytes moved so far.
    @TaskLocal public static var progress: (@Sendable (Int64) -> Void)?
}

/// Limits how many transfers run at once. A caller that's cancelled leaves the queue straight
/// away, so a stuck transfer can't hold a line of callers nobody wants any more.
actor TransferGate {
    private var available: Int
    private var waiting: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []

    init(limit: Int) {
        available = limit
    }

    /// How many callers are queued.
    var queued: Int {
        waiting.count
    }

    func acquire() async throws {
        if available > 0 {
            available -= 1
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await join(id)
        } onCancel: {
            Task { await self.leave(id) }
        }
    }

    private func join(_ id: UUID) async throws {
        let _: Void = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            if Task.isCancelled {
                continuation.resume(throwing: RemoteError.cancelled)
            } else {
                waiting.append((id, continuation))
            }
        }
    }

    private func leave(_ id: UUID) {
        if let index = waiting.firstIndex(where: { $0.id == id }) {
            waiting.remove(at: index).continuation.resume(throwing: RemoteError.cancelled)
        }
    }

    func release() {
        if waiting.isEmpty {
            available += 1
        } else {
            waiting.removeFirst().continuation.resume()
        }
    }
}

/// A result the engine may leave out.
private protocol ValueOptional {
    init()
}

private struct Empty: Decodable, Sendable, ValueOptional {}

private struct ProbeResult: Decodable, Sendable {
    var versions: Bool
}

private struct OpenResult: Decodable, Sendable, ValueOptional {
    var vaultID: String?
    var revision: Int?
}

private struct SavedKey: Encodable {
    var key: String
}

private struct HostKeyRequest: Encodable {
    var host: String
    var port: Int
}

private struct Arguments: Encodable {
    var drive: String
    var path: String?
    var source: String?
    var destination: String?
    var offset: Int64?
    var length: Int64?
    var baseVersion: String?
    var failOnConflict: Bool?
    var staged: String?
    // What the saving device knows about the file, for its details.
    var modifiedNs: Int64?
    var createdNs: Int64?
    var bundleType: String?
    /// What a download must match, from the file's details.
    var sha256: String?
}

private struct EngineStage: Decodable, Sendable, ValueOptional {
    var staged = ""

    init() {}
}

private struct EngineSave: Decodable, Sendable {
    var item: EngineItem
    var conflictPath: String?
    var detailsMissed: String?
}

private struct DriveConfiguration: Encodable {
    var id: String
    var kind: String
    var url: String?
    var host: String?
    var port: Int?
    var user: String?
    var password: String?
    var keyPem: String?
    var keyPassphrase: String?
    var hostKey: String?
    var rootPath: String?
    var encrypted: Bool
    var vaultPassword: String?
    var createVault: Bool
    var expectedVaultID: String?
    var minRevision: Int?
    var deviceID: String?
    var deviceName: String?
    var readOnly: Bool
    /// Safe, Unsafe or Read-only. A read-only connection stays read-only whatever this says.
    var mode: String
    var allowInsecure: Bool
    /// Which app and version writes, as file details record it.
    var appName: String

    init(id: String, connection: Connection, credentials: Credentials, createVault: Bool, device: DeviceInfo?) {
        appName = Self.appName
        self.id = id
        switch connection.endpoint {
        case .webDAV(let url):
            kind = "webdav"
            self.url = url.absoluteString
        case .sftp(let host, let port):
            kind = "sftp"
            self.host = host
            self.port = port
        case .localFolder:
            kind = "local"
        }
        user = connection.username
        password = credentials.password
        keyPem = credentials.privateKeyPEM
        keyPassphrase = credentials.privateKeyPassphrase
        hostKey = connection.hostKey
        rootPath = connection.rootPath
        encrypted = connection.isEncrypted
        vaultPassword = credentials.vaultPassword
        self.createVault = createVault
        expectedVaultID = connection.vaultID
        minRevision = connection.vaultRevision
        deviceID = device?.id
        deviceName = device?.name
        readOnly = connection.isReadOnly
        mode = connection.settings.mode.rawValue
        allowInsecure = connection.allowsInsecure
    }

    /// Such as "CloudAccess 1.0 (macOS 27.2)". No device name: details can outlive a device.
    static let appName: String = {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let system = ProcessInfo.processInfo.operatingSystemVersion
        #if os(macOS)
        let product = "CloudAccess", platform = "macOS"
        #else
        let product = "CloudWanderer", platform = "iOS"
        #endif
        return "\(product) \(version) (\(platform) \(system.majorVersion).\(system.minorVersion))"
    }()
}

private struct EngineItem: Decodable, Sendable {
    var path: String
    var isDirectory: Bool
    var size: Int64
    var modifiedNs: Int64
    var versionID: String?
    // From the file's details, only when they passed every check in the engine.
    var ownModifiedNs: Int64?
    var createdNs: Int64?
    var sha256: String?
    var bundleType: String?

    func remoteItem(at location: RemotePath) -> RemoteItem {
        RemoteItem(
            path: location,
            kind: isDirectory ? .directory : .file,
            size: isDirectory ? nil : size,
            modified: Self.date(modifiedNs),
            versionID: versionID,
            ownModified: ownModifiedNs.flatMap(Self.date),
            created: createdNs.flatMap(Self.date),
            checksum: sha256,
            bundleType: bundleType
        )
    }

    private static func date(_ nanoseconds: Int64) -> Date? {
        nanoseconds == 0 ? nil : Date(timeIntervalSince1970: Double(nanoseconds) / 1e9)
    }
}

private struct CallResult<Value: Decodable>: Decodable {
    var value: Value?
    var error: EngineFailure?
}

private struct EngineFailure: Decodable {
    var kind: String
    var message: String
    var status: Int?
    /// Which part of reaching the server failed, for an unreachable server only.
    var reason: String?

    func remoteError(at path: RemotePath) -> RemoteError {
        switch kind {
        case "notFound": return .notFound(path)
        case "alreadyExists": return .alreadyExists(path)
        case "parentMissing": return .parentMissing(path)
        case "forbidden": return .forbidden(path)
        case "readOnly": return .readOnly
        case "locked": return .locked(path)
        case "versionMismatch": return .versionMismatch(path)
        case "cancelled": return .cancelled
        case "unauthorized": return .unauthorized
        case "insufficientStorage": return .insufficientStorage
        case "unreachable": return .unreachable(message, reason: reason.flatMap(UnreachableReason.init(rawValue:)) ?? .unknown)
        case "tooSlow": return .tooSlow(path)
        case "tooLarge": return .tooLarge(path)
        case "tooManyItems": return .tooManyItems(path)
        case "server": return .server(status: status ?? 500)
        case "wrongPassword": return .vault(.wrongPassword)
        case "vaultMissing": return .vault(.missing)
        case "vaultNotCreated": return .vault(.notCreated)
        case "vaultMismatch": return .vault(.mismatch)
        case "vaultRollback": return .vault(.rollback)
        case "vaultRetired": return .vault(.retired)
        case "vaultUnsupported": return .vault(.unsupported)
        case "vaultMalformed": return .vault(.malformed)
        case "vaultEncrypted": return .vault(.encrypted)
        case "nameTooLong": return .nameTooLong(path)
        // The engine can't tell what it is, and a folder is the case that must never be left out.
        case "notAPlainFile": return .notAPlainFile(path, .folder)
        case "unreadableHere": return .unreadableHere(path, message)
        case "hostKeyUnknown": return .hostKeyUnknown
        case "hostKeyChanged": return .hostKeyChanged
        case "unsupportedServer": return .unsupportedServer(message)
        default: return .failed(path, message)
        }
    }
}
