// Apache 2 license - developer@infinitecontext.com

import CryptoKit
import Foundation
import SyncCore

/// The two version components macOS stores for each item. Apple limits each to 128 bytes, so
/// neither may grow with a file name or an ETag.
public enum ItemVersions {
    private static func hash(_ text: String) -> Data {
        let digest = SHA256.hash(data: Data(text.utf8))
        return Data(digest.map { String(format: "%02x", $0) }.joined().utf8)
    }

    /// Holds the server's version ID, because macOS hands this back as the base of an edit,
    /// and that's what a save has to compare against. A folder has no content version.
    public static func content(of item: SyncItem) -> Data {
        guard item.kind == .file else { return hash("folder") }
        if let versionID = item.versionID {
            return Data(versionID.utf8)
        }
        return hash(item.version)
    }

    /// What macOS has to notice about an item beyond its content goes in here, because it ignores
    /// an item whose version hasn't changed. That covers a badge and a pin, whose content policy
    /// would otherwise never reach it. The content version stays the same, so nothing downloads.
    public static func metadata(of item: SyncItem, isUnavailable: Bool = false, isFailed: Bool = false) -> Data {
        var state = ""
        if isUnavailable { state += "|unavailable" }
        if isFailed { state += "|failed" }
        if item.isPinned { state += "|pinned" }
        // Dates from the file's details, only when there are some, so an item without them keeps
        // the version it always had, and macOS hears dates that arrive after the bytes.
        if let ownModified = item.ownModified { state += "|m\(Int64(ownModified.timeIntervalSince1970 * 1e6))" }
        if let created = item.created { state += "|c\(Int64(created.timeIntervalSince1970 * 1e6))" }
        return hash("\(item.parentID ?? "")/\(item.name)\(state)")
    }

    /// The version ID in a base version from macOS. `nil` means there's no agreed version,
    /// so an existing file on the server is treated as a peer's.
    public static func baseVersion(from content: Data, beforeFirstSync: Data) -> String? {
        guard content != beforeFirstSync, !content.isEmpty else { return nil }
        return String(data: content, encoding: .utf8)
    }
}
