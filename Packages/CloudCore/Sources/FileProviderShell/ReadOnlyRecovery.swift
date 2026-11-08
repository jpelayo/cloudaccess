// Apache 2 license - developer@infinitecontext.com

import SyncCore

/// Finishes a database recovery on a drive that only reads, such as the iPhone's. On the Mac the
/// app does this, after walking the whole server, because what macOS holds may be the only copy of
/// an edit and has to be matched up first. The iPhone holds nothing that isn't on the server and
/// its app can't reach this database, so the extension finishes on its own: once the drive's top
/// lists again, a new epoch has the system list everything from scratch.
public enum ReadOnlyRecovery {
    /// - Returns: Whether a recovery was finished, so the system should be told to look again.
    @discardableResult
    public static func finishIfNeeded(store: SyncStore, syncer: Syncer) async throws -> Bool {
        guard try store.needsRebuild() else { return false }
        // A listing that fails leaves the flag, so this runs again next time.
        try await syncer.refresh(folderID: SyncItem.rootID)
        try store.finishReadOnlyRecovery()
        return true
    }
}
