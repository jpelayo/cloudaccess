// Apache 2 license - developer@infinitecontext.com

import CloudCore
import FileProvider
import MountKit
import SyncCore
import UniformTypeIdentifiers

public final class FileProviderItem: NSObject, NSFileProviderItem {
    private let item: SyncItem
    private let isReadOnly: Bool
    private let isUnavailable: Bool
    private let isFailed: Bool
    private let marks: ItemMarks?

    /// - Parameters:
    ///   - isUnavailable: The drive is offline and this file isn't on this Mac.
    ///   - isFailed: This item is in the panel's list of files that couldn't sync.
    ///   - marks: What a person set on it on this device, which only the iPhone hands back.
    public init(
        _ item: SyncItem, isReadOnly: Bool, isUnavailable: Bool = false, isFailed: Bool = false,
        marks: ItemMarks? = nil
    ) {
        self.item = item
        self.isReadOnly = isReadOnly
        self.isUnavailable = isUnavailable
        self.isFailed = isFailed
        self.marks = marks
    }

    public var itemIdentifier: NSFileProviderItemIdentifier {
        Identifiers.identifier(item.id)
    }

    public var parentItemIdentifier: NSFileProviderItemIdentifier {
        item.parentID.map(Identifiers.identifier) ?? .rootContainer
    }

    /// macOS aborts on an item with an empty name, and that includes the root.
    public var filename: String {
        item.isRoot ? "root" : item.name
    }

    public var contentType: UTType {
        switch item.kind {
        case .directory:
            return .folder
        case .file:
            // `.pkgf` means nothing to the type system, and the extension before it can't say if
            // this was a package. Apple's sample, which sets the same flag, answers `.item`.
            if item.isFlattenedPackage {
                return .item
            }
            let fileExtension = (item.name as NSString).pathExtension
            return UTType(filenameExtension: fileExtension) ?? .data
        }
    }

    public var capabilities: NSFileProviderItemCapabilities {
        let all = allCapabilities
        #if os(macOS)
        return item.isFlattenedPackage ? all.subtracting(.allowsEvicting) : all
        #else
        // The iPhone never sends anything, so a package there is only ever a copy of the server's,
        // and the space it takes can always be given back.
        return all
        #endif
    }

    private var allCapabilities: NSFileProviderItemCapabilities {
        if isReadOnly {
            return item.kind == .directory
                ? [.allowsReading, .allowsContentEnumerating, .allowsEvicting]
                : [.allowsReading, .allowsEvicting]
        }
        switch item.kind {
        case .directory:
            // The root is the drive itself, so it can't be renamed or deleted.
            if item.isRoot {
                return [.allowsReading, .allowsContentEnumerating, .allowsAddingSubItems, .allowsEvicting]
            }
            return [.allowsReading, .allowsContentEnumerating, .allowsAddingSubItems,
                    .allowsRenaming, .allowsReparenting, .allowsDeleting, .allowsEvicting]
        case .file:
            return [.allowsReading, .allowsWriting, .allowsRenaming, .allowsReparenting,
                    .allowsDeleting, .allowsEvicting]
        }
    }

    /// A pinned folder stays downloaded, and everything inside it inherits that. The iPhone has
    /// no pinning, so everything there is downloaded when it's opened.
    public var contentPolicy: NSFileProviderContentPolicy {
        #if os(macOS)
        item.isPinned ? .downloadEagerlyAndKeepDownloaded : .inherited
        #else
        .inherited
        #endif
    }

    #if !os(macOS)
    // Kept on the iPhone and handed back, as Apple asks. Without them Recents, tags and
    // favourites fall away. The Mac doesn't implement these, so what macOS sees there is unchanged.

    public var lastUsedDate: Date? {
        marks?.lastUsed
    }

    public var tagData: Data? {
        marks?.tags
    }

    public var favoriteRank: NSNumber? {
        marks?.favoriteRank.map { NSNumber(value: $0) }
    }
    #endif

    public var documentSize: NSNumber? {
        item.size.map(NSNumber.init(value:))
    }

    /// The file's own date when its details say, otherwise the server's. On WebDAV the server's is
    /// when the file arrived.
    public var contentModificationDate: Date? {
        item.ownModified ?? item.modified
    }

    /// Only from the file's details. Neither server keeps one of its own.
    public var creationDate: Date? {
        item.created
    }

    public var itemVersion: NSFileProviderItemVersion {
        NSFileProviderItemVersion(
            contentVersion: ItemVersions.content(of: item),
            metadataVersion: ItemVersions.metadata(of: item, isUnavailable: isUnavailable, isFailed: isFailed))
    }
}

#if os(macOS)
/// Badges are declared in the Mac extension's Info.plist only, so only the Mac shows them.
extension FileProviderItem: NSFileProviderItemDecorating {
    /// Conflict copies stand out in Finder, and so do files that failed or can't be opened offline.
    /// Finder gives apps no way to dim a file, so a badge is the closest thing.
    public var decorations: [NSFileProviderItemDecorationIdentifier]? {
        var found: [NSFileProviderItemDecorationIdentifier] = []
        if item.name.contains(" (conflict from ") {
            found.append(NSFileProviderItemDecorationIdentifier("com.infinitecontext.CloudMount.conflict"))
        }
        if isUnavailable {
            found.append(NSFileProviderItemDecorationIdentifier("com.infinitecontext.CloudMount.unavailable"))
        }
        if isFailed {
            found.append(NSFileProviderItemDecorationIdentifier("com.infinitecontext.CloudMount.failed"))
        }
        return found.isEmpty ? nil : found
    }
}
#endif
