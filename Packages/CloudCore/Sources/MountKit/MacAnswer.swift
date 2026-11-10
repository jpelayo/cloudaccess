// Apache 2 license - developer@infinitecontext.com

import CloudCore
import Foundation
import SyncCore

/// A name on the server belongs to another item. macOS renames one of the two and tries again,
/// but it needs to be told which item holds the name.
public struct NameTaken: Error, Equatable, Sendable {
    public var path: RemotePath
    /// The item that has the name, as this Mac now knows it, or nil if it couldn't be listed.
    public var holder: SyncItem?

    public init(path: RemotePath, holder: SyncItem?) {
        self.path = path
        self.holder = holder
    }
}

/// What macOS is told when a request fails. macOS acts on each answer: it drops its copy on "no
/// such item", stops trying on "can't sync" until something changes, and renames on "name taken".
/// So the choice is made here, where tests reach it, and the extension only puts it in Apple's
/// terms.
public enum MacAnswer: Equatable, Sendable {
    /// Gone from the server. macOS removes its copy, so this needs proof.
    case noSuchItem
    /// Another item has the name. macOS renames one of them and tries again.
    case nameTaken(SyncItem?)
    /// Try again later. macOS holds back the whole drive for a while.
    case tryLater
    /// This item waits until it changes on disk or a person presses Try Again. Anything that ends
    /// here has to be listed with why, or nobody would know it stopped.
    case cannotSync
    case signIn
    case outOfSpace
    case cancelled
    /// The list of changes moved on without macOS, so it lists everything again.
    case startOver
    /// A peer changed it, and macOS asked to merge rather than have a conflict copy made.
    case peerChanged
    /// A peer changed it, so the delete is refused and their version comes back.
    case deletionRefused
    /// Keep it on this Mac only. macOS answers this with a delete, which looks like a person's,
    /// so only a create of something that can't be on the server gets it.
    case leaveOut
    /// The request is done after all, such as a delete of something already gone.
    case done
    /// Already in macOS's own terms.
    case asIs

    /// What failed.
    public enum Request: Sendable, Equatable {
        /// Looking up an item, downloading one, or listing a folder.
        case read
        /// - Parameters:
        ///   - isSafelyNew: What `Mutations.isSafelyNew` says, so nothing on the server is ever
        ///     left out.
        ///   - holdsData: A file with bytes, or a folder, which may hold files nobody has sent.
        ///     Only a re-import of a file with no bytes holds nothing.
        case create(isSafelyNew: Bool, holdsData: Bool)
        /// - Parameter hasContents: The call carries bytes, which may be the only copy of an edit.
        case modify(hasContents: Bool, failOnConflict: Bool)
        case delete
    }

    public static func to(_ request: Request, failingWith error: Error) -> MacAnswer {
        let answer = plain(error)
        switch request {
        case .read:
            return answer
        case .create(let isSafelyNew, let holdsData):
            if let remote = error as? RemoteError, remote.canNeverBeSent {
                // It's on the failed list with why. If it could be on the server, it only waits.
                return isSafelyNew ? .leaveOut : .cannotSync
            }
            // A new file's bytes, or a new folder's files, exist only on this Mac, and macOS
            // deletes them on "no such item", as it would an edit's.
            if holdsData, answer == .noSuchItem {
                return .cannotSync
            }
            return answer
        case .modify(let hasContents, let failOnConflict):
            if failOnConflict, case RemoteError.versionMismatch = error {
                return .peerChanged
            }
            // macOS deletes its copy on "no such item", and these bytes may be the only copy of
            // an edit. It re-creates the file only for changes made after this call.
            if hasContents, answer == .noSuchItem {
                return .cannotSync
            }
            return answer
        case .delete:
            switch error {
            case SyncError.itemNotFound, RemoteError.notFound:
                // Apple asks for success when the item may already be gone from the server.
                return .done
            case RemoteError.versionMismatch:
                return .deletionRefused
            case RemoteError.readOnly:
                // The item is still on the server, and this has the system put it back, where
                // "can't sync" would leave it gone here and still there.
                return .deletionRefused
            default:
                return answer
            }
        }
    }

    /// Whether a folder that couldn't be listed shows what's known, instead of an error. macOS
    /// drops a folder on "no such item", and one not-found never proves that: Apache gives them
    /// for a moment during saves, a folder's removal is decided from its parent's listing with
    /// two direct checks, and the drive's root can't be removed at all.
    public static func listingShowsWhatsKnown(after error: Error, knowsItems: Bool) -> Bool {
        guard let remote = error as? RemoteError else { return false }
        if case .notFound = remote { return true }
        return remote.leavesListingAlone && knowsItems
    }

    private static func plain(_ error: Error) -> MacAnswer {
        switch error {
        case SyncError.itemNotFound:
            return .noSuchItem
        case SyncError.anchorExpired:
            return .startOver
        case SyncError.recovering:
            // The app tells macOS to carry on once it's done.
            return .tryLater
        case SyncError.held:
            // One file, so this can't stop the drive. macOS keeps the file and asks again later.
            return .cannotSync
        case is CancellationError:
            // A task stopped part way, such as during a second look. Nothing is wrong with the item.
            return .cancelled
        case let taken as NameTaken:
            return .nameTaken(taken.holder)
        case let remote as RemoteError:
            return answer(for: remote)
        default:
            // macOS only accepts its own error domains, so anything else is put in its terms.
            let domain = (error as NSError).domain
            return domain == "NSFileProviderErrorDomain" || domain == NSCocoaErrorDomain ? .asIs : .cannotSync
        }
    }

    private static func answer(for remote: RemoteError) -> MacAnswer {
        switch remote {
        case .notFound:
            return .noSuchItem
        case .alreadyExists:
            return .nameTaken(nil)
        case .nameTooLong, .reservedName:
            // Never `leaveOut` here. This can be a file on the server that's being renamed.
            return .cannotSync
        case .locked:
            // One busy file. Saying the server's unreachable would stop the whole drive for a while.
            return .cannotSync
        case .unauthorized, .vault, .hostKeyUnknown, .hostKeyChanged, .unsupportedServer:
            return .signIn
        case .unreachable, .server:
            return .tryLater
        case .insufficientStorage:
            return .outOfSpace
        case .cancelled:
            return .cancelled
        case .parentMissing, .forbidden, .versionMismatch, .notAPlainFile, .unreadableHere, .readOnly,
             .failed, .tooSlow, .tooLarge, .tooManyItems:
            return .cannotSync
        }
    }
}
