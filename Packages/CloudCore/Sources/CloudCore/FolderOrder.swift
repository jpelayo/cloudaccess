// Apache 2 license - developer@infinitecontext.com

import Foundation

/// How a folder's items are listed on the iPhone. Folders go on top only when the person asks for
/// that. Whatever the server gave no size or date for goes last either way, and items alike in
/// what's sorted on fall back to their names, so a list keeps its order when it refreshes.
public enum FolderOrder: String, CaseIterable, Sendable, Identifiable {
    case nameAscending
    case nameDescending
    case modifiedNewest
    case modifiedOldest
    case createdNewest
    case createdOldest
    case kind
    case sizeLargest
    case sizeSmallest

    public var id: String { rawValue }

    /// What the order is called, in the language shown. The raw value is what's saved.
    public var title: String {
        switch self {
        case .nameAscending: Words.text("Name, A to Z")
        case .nameDescending: Words.text("Name, Z to A")
        case .modifiedNewest: Words.text("Modified, newest first")
        case .modifiedOldest: Words.text("Modified, oldest first")
        case .createdNewest: Words.text("Created, newest first")
        case .createdOldest: Words.text("Created, oldest first")
        case .kind: Words.text("Kind")
        case .sizeLargest: Words.text("Size, largest first")
        case .sizeSmallest: Words.text("Size, smallest first")
        }
    }

    /// What a folder shows. Names that start with a dot are hidden unless asked for, as in Finder.
    /// What the drive keeps for itself never shows: it isn't the person's.
    public static func shown(_ items: [RemoteItem], showsHidden: Bool) -> [RemoteItem] {
        items.filter { !RemotePath.isReservedName($0.path.name) && (showsHidden || !$0.isHidden) }
    }

    /// - Parameter foldersFirst: Puts folders above files, each sorted on their own. Otherwise they
    ///   mix, as in Finder.
    public func sorted(_ items: [RemoteItem], foldersFirst: Bool) -> [RemoteItem] {
        items.sorted { inOrder($0, $1, foldersFirst: foldersFirst) }
    }

    private func inOrder(_ a: RemoteItem, _ b: RemoteItem, foldersFirst: Bool) -> Bool {
        // A folder is a kind of its own, so Kind keeps folders together whatever was asked.
        if a.kind != b.kind, foldersFirst || self == .kind {
            return a.kind == .directory
        }
        let byName = Self.compareNames(a, b)
        switch self {
        case .nameAscending:
            return byName == .orderedAscending
        case .nameDescending:
            return byName == .orderedDescending
        // A file's own date when its details give one, otherwise the server's.
        case .modifiedNewest:
            return Self.lastIfMissing(a.shownModified, b.shownModified, byName: byName, ascending: false)
        case .modifiedOldest:
            return Self.lastIfMissing(a.shownModified, b.shownModified, byName: byName, ascending: true)
        // Only file details say when something was created, so the rest go last.
        case .createdNewest:
            return Self.lastIfMissing(a.created, b.created, byName: byName, ascending: false)
        case .createdOldest:
            return Self.lastIfMissing(a.created, b.created, byName: byName, ascending: true)
        case .kind:
            // A dot in a folder's name doesn't give it a type.
            guard a.kind == .file else { return byName == .orderedAscending }
            let typeA = Self.type(of: a), typeB = Self.type(of: b)
            if typeA != typeB {
                // Files with no ending have no type to group by, so they go after the rest.
                if typeA.isEmpty || typeB.isEmpty { return typeB.isEmpty }
                return typeA < typeB
            }
            return byName == .orderedAscending
        case .sizeLargest:
            return Self.lastIfMissing(Self.size(of: a), Self.size(of: b), byName: byName, ascending: false)
        case .sizeSmallest:
            return Self.lastIfMissing(Self.size(of: a), Self.size(of: b), byName: byName, ascending: true)
        }
    }

    /// A folder has no size of its own, even when a server reports one, such as 0, so it goes with
    /// the files whose size isn't known, by name.
    private static func size(of item: RemoteItem) -> Int64? {
        item.kind == .file ? item.size : nil
    }

    /// Numbers in names read as numbers, and case and accents don't split what belongs together,
    /// as in Finder.
    private static func compareNames(_ a: RemoteItem, _ b: RemoteItem) -> ComparisonResult {
        let result = a.path.name.localizedStandardCompare(b.path.name)
        return result == .orderedSame ? a.path.name.compare(b.path.name) : result
    }

    private static func type(of item: RemoteItem) -> String {
        (item.path.name as NSString).pathExtension.lowercased()
    }

    private static func lastIfMissing<Value: Comparable>(
        _ a: Value?, _ b: Value?, byName: ComparisonResult, ascending: Bool
    ) -> Bool {
        switch (a, b) {
        case let (a?, b?) where a != b:
            return ascending ? a < b : a > b
        case (nil, _?):
            return false
        case (_?, nil):
            return true
        default:
            return byName == .orderedAscending
        }
    }
}

extension RemoteItem {
    /// Its name starts with a dot, which macOS and Linux keep out of sight.
    public var isHidden: Bool {
        path.name.hasPrefix(".")
    }
}
