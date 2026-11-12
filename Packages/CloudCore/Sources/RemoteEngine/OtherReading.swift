// Apache 2 license - developer@infinitecontext.com

import CloudCore
import Foundation

extension RemoteEngine {
    /// On SFTP, `Documents` and `/Documents` are two places: one in the home folder, one from the
    /// server's top. When the one asked for isn't there, this looks for the other, read-only and
    /// unencrypted, so a form can offer it. Nil when it isn't there either, or on WebDAV.
    public static func otherReading(of connection: Connection, credentials: Credentials) async -> String? {
        guard case .sftp = connection.endpoint, let other = ServerFolder.otherReading(of: connection.rootPath)
        else { return nil }
        var probe = connection
        probe.rootPath = other
        probe.isEncrypted = false
        probe.vaultID = nil
        probe.vaultRevision = nil
        probe.settings.mode = .readOnly
        var signIn = credentials
        signIn.vaultPassword = nil
        guard let engine = try? await RemoteEngine(connection: probe, credentials: signIn),
              (try? await engine.list(.root)) != nil
        else { return nil }
        return other
    }
}
