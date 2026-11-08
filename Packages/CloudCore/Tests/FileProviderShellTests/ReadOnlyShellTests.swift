// Apache 2 license - developer@infinitecontext.com

import CloudCore
import FileProvider
import FileProviderShell
import Foundation
import MountKit
import SyncCore
import Testing

/// The iPhone's Files extension only reads. Files offers what an item's capabilities allow, so
/// these are what keep a person from trying to change anything there.
@Suite struct ReadOnlyShellTests {
    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReadOnlyShellTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func item(_ name: String, kind: RemoteItem.Kind, isPinned: Bool = false) -> SyncItem {
        SyncItem(
            id: UUID().uuidString, parentID: SyncItem.rootID, name: name, kind: kind, size: 10,
            modified: nil, version: "v1", versionID: "v1", generation: 0, isPinned: isPinned)
    }

    private let changes: NSFileProviderItemCapabilities = [
        .allowsWriting, .allowsRenaming, .allowsReparenting, .allowsDeleting, .allowsAddingSubItems,
    ]

    /// A place like the iPhone's: always read-only, and serving only the drives it's told to.
    private func place(
        folder: URL, isAlwaysReadOnly: Bool, serves: @escaping @Sendable (Connection) -> Bool = { _ in true }
    ) -> DrivePlace {
        DrivePlace(
            drives: { DriveStore(directory: folder) },
            database: { saved, id in (try saved.databaseURL(for: id), try saved.backupURL(for: id)) },
            device: { _ in nil },
            isAlwaysReadOnly: isAlwaysReadOnly, serves: serves)
    }

    private func savedDrive(in folder: URL) throws -> Connection {
        let connection = Connection(displayName: "Work", endpoint: .webDAV(url: URL(string: "https://example.invalid/dav")!))
        try DriveStore(directory: folder).save(connection)
        return connection
    }

    @Test func aReadOnlyItemOffersNothingThatChangesTheDrive() {
        for kind in [RemoteItem.Kind.file, .directory] {
            let shown = FileProviderItem(item("Report.docx", kind: kind), isReadOnly: true)
            #expect(shown.capabilities.isDisjoint(with: changes), "\(kind)")
            #expect(shown.capabilities.contains(.allowsReading), "\(kind)")
        }
    }

    /// The drive's own setting says it can be written to, and the iPhone still never offers it.
    @Test func theIPhoneShowsEveryDriveAsReadOnly() async throws {
        let folder = try temporaryFolder()
        let connection = try savedDrive(in: folder)
        #expect(!connection.isReadOnly)
        let connector = Connector(
            domainIdentifier: connection.id.uuidString, place: place(folder: folder, isAlwaysReadOnly: true))
        let local = try await connector.local()
        #expect(local.isReadOnly())
        let shown = local.present(item("Report.docx", kind: .file))
        #expect(shown.capabilities.isDisjoint(with: changes))
    }

    /// The Mac's place is unchanged by the move into this package: a drive it can write to stays
    /// one it can write to.
    @Test func theMacStillWritesWhereItMay() async throws {
        let folder = try temporaryFolder()
        let connection = try savedDrive(in: folder)
        let connector = Connector(
            domainIdentifier: connection.id.uuidString, place: place(folder: folder, isAlwaysReadOnly: false))
        let local = try await connector.local()
        #expect(!local.isReadOnly())
        #expect(local.present(item("Report.docx", kind: .file)).capabilities.contains(.allowsWriting))
    }

    /// A drive the extension mustn't serve, such as a real one in a test build, isn't opened at all.
    @Test func aDriveTheExtensionMustntServeIsNeverOpened() async throws {
        let folder = try temporaryFolder()
        let connection = try savedDrive(in: folder)
        let connector = Connector(
            domainIdentifier: connection.id.uuidString,
            place: place(folder: folder, isAlwaysReadOnly: true, serves: { _ in false }))
        await #expect(throws: NSFileProviderError.self) {
            _ = try await connector.local()
        }
        let database = try DriveStore(directory: folder).databaseURL(for: connection.id)
        #expect(!FileManager.default.fileExists(atPath: database.path))
    }

    /// Pinning is the Mac's alone, and moving this code here kept it.
    @Test func aPinnedFolderStillStaysDownloadedOnTheMac() {
        let pinned = FileProviderItem(item("Projects", kind: .directory, isPinned: true), isReadOnly: false)
        #expect(pinned.contentPolicy == .downloadEagerlyAndKeepDownloaded)
    }

    /// Asking a read-only drive for a change, or listing a folder too big for Files, gets an
    /// answer that makes macOS stop asking, never one that drops the item.
    @Test func whatTheIPhoneRefusesIsNeverCalledGone() {
        let path = RemotePath("/Big")!
        let identifier = NSFileProviderItemIdentifier("some-id")
        for error in [RemoteError.readOnly, .tooManyItems(path)] {
            let mapped = Errors.map(error, for: .read, identifier: identifier) as? NSFileProviderError
            #expect(mapped?.code == .cannotSynchronize, "\(error)")
        }
    }

    /// A refused delete carries the item as it stands, as Apple asks, so the system can put it
    /// back from that.
    @Test func aRefusedDeleteCarriesTheItem() {
        let shown = FileProviderItem(item("Report.docx", kind: .file), isReadOnly: true)
        let error = Errors.map(
            RemoteError.readOnly, for: .delete, identifier: shown.itemIdentifier, item: shown) as NSError?
        #expect(error?.domain == NSFileProviderErrorDomain)
        #expect(error?.code == NSFileProviderError.Code.deletionRejected.rawValue)
        #expect(error?.userInfo[NSFileProviderErrorItemKey] != nil)
        // Without the item there's still the right code.
        let bare = Errors.map(RemoteError.readOnly, for: .delete, identifier: shown.itemIdentifier) as NSError?
        #expect(bare?.code == NSFileProviderError.Code.deletionRejected.rawValue)
    }

    /// Drives keep no trash on this device, and Apple asks for this refusal rather than a listing.
    @Test func theTrashIsRefusedAsUnsupported() {
        #expect(throws: CocoaError.self) { try Identifiers.checkNotTrash(.trashContainer) }
        #expect(throws: Never.self) { try Identifiers.checkNotTrash(.rootContainer) }
        #expect(throws: Never.self) { try Identifiers.checkNotTrash(.workingSet) }
    }

    /// The Mac keeps a package downloaded until bringing one back is proved there. Only the
    /// iPhone, which never sends anything, lets one go.
    @Test func theMacStillKeepsPackagesDownloaded() {
        let package = FileProviderItem(item("Budget.numbers.pkgf", kind: .file), isReadOnly: true)
        #expect(!package.capabilities.contains(.allowsEvicting))
        #expect(package.decorations == nil)
    }
}
