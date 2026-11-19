// Apache 2 license - developer@infinitecontext.com

import CloudCore
import Foundation

extension RemoteEngine {
    /// What the drive's folder holds, read before anything is set up, so an add form can say
    /// whether it can be encrypted. It opens the folder plain and read-only, so nothing is written:
    /// a folder that's an encrypted drive refuses that, and anything else is listed. The listing
    /// leaves `.cloudmount` out, as it does everywhere.
    public static func folderContents(of connection: Connection, credentials: Credentials) async throws -> FolderContents {
        var probe = connection
        probe.isEncrypted = false
        probe.vaultID = nil
        probe.vaultRevision = nil
        probe.settings.mode = .readOnly
        var signIn = credentials
        signIn.vaultPassword = nil
        do {
            let engine = try await RemoteEngine(connection: probe, credentials: signIn)
            return try await engine.list(.root).isEmpty ? .empty : .plainFiles
        } catch RemoteError.vault(.encrypted) {
            return .encryptedDrive
        } catch RemoteError.notFound(let path) where path.isRoot {
            // Not there yet: connecting makes it, empty.
            return .empty
        }
    }
}
