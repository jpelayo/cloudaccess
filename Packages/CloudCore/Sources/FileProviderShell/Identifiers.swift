// Apache 2 license - developer@infinitecontext.com

import CloudCore
import FileProvider
import MountKit
import SyncCore

public enum Identifiers {
    public static func syncID(_ identifier: NSFileProviderItemIdentifier) -> String {
        identifier == .rootContainer ? SyncItem.rootID : identifier.rawValue
    }

    public static func identifier(_ syncID: String) -> NSFileProviderItemIdentifier {
        syncID == SyncItem.rootID ? .rootContainer : NSFileProviderItemIdentifier(syncID)
    }

    /// Drives keep no trash of their own on this device, and Apple asks a provider without one to
    /// refuse the trash container this way rather than list it.
    public static func checkNotTrash(_ identifier: NSFileProviderItemIdentifier) throws {
        if identifier == .trashContainer {
            throw CocoaError(.featureUnsupported)
        }
    }

    /// What this edit started from, as macOS reports it. The database can't answer this: a
    /// poll may have moved it on while the edit waited.
    public static func baseVersion(of version: NSFileProviderItemVersion) -> String? {
        ItemVersions.baseVersion(
            from: version.contentVersion,
            beforeFirstSync: NSFileProviderItemVersion.beforeFirstSyncComponent)
    }
}

public enum Errors {
    /// `MacAnswer` decides what macOS hears, where tests reach it. This only spells it in Apple's
    /// terms, and decides nothing.
    /// - Parameter item: The item as it stands, for a refused delete. Apple asks for it, because
    ///   the system puts the item back from what this says.
    /// - Returns: Nil when the request counts as done.
    public static func map(
        _ error: Error, for request: MacAnswer.Request, identifier: NSFileProviderItemIdentifier,
        item: FileProviderItem? = nil
    ) -> Error? {
        switch MacAnswer.to(request, failingWith: error) {
        case .noSuchItem:
            return NSError.fileProviderErrorForNonExistentItem(withIdentifier: identifier)
        case .nameTaken(let holder?):
            // Apple asks for the item that has the name, so macOS can rename one of them.
            return NSError.fileProviderErrorForCollision(with: FileProviderItem(holder, isReadOnly: false))
        case .nameTaken(nil):
            return NSFileProviderError(.filenameCollision)
        case .tryLater:
            return NSFileProviderError(.serverUnreachable)
        case .cannotSync:
            return NSFileProviderError(.cannotSynchronize)
        case .signIn:
            return NSFileProviderError(.notAuthenticated)
        case .outOfSpace:
            return NSFileProviderError(.insufficientQuota)
        case .cancelled:
            return CocoaError(.userCancelled)
        case .startOver:
            return NSFileProviderError(.syncAnchorExpired)
        case .peerChanged:
            return NSFileProviderError(.localVersionConflictingWithServer)
        case .deletionRefused:
            return item.map { NSError.fileProviderErrorForRejectedDeletion(of: $0) }
                ?? NSFileProviderError(.deletionRejected)
        case .leaveOut:
            return NSFileProviderError(.excludedFromSync)
        case .done:
            return nil
        case .asIs:
            return error
        }
    }
}

/// Carries a File Provider callback into a task. macOS allows these to be called from any
/// thread, but they aren't marked as sendable.
public struct Unchecked<Value>: @unchecked Sendable {
    public let value: Value

    public init(_ value: Value) {
        self.value = value
    }
}
