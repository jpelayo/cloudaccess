// Apache 2 license - developer@infinitecontext.com

import CloudCore
import RemoteEngine
import SwiftUI

/// A new SFTP server's key, waiting for a person to trust it, and what to carry on with after.
/// Trusting it carries on with what was pressed, so it's one press and one question.
struct PendingTrust: Identifiable {
    let id = UUID()
    let host: String
    let key: RemoteEngine.HostKey
    let resume: () -> Void
}

enum ServerTrust {
    /// The key a server presents, and whether a person has to be asked before it's used. A key
    /// already trusted for this server by another drive here isn't asked about again.
    static func offered(host: String, port: Int, among drives: [Connection]) async throws -> (key: RemoteEngine.HostKey, mustAsk: Bool) {
        let key = try await RemoteEngine.hostKey(host: host, port: port)
        return (key, HostTrust.decide(offered: key.key, host: host, port: port, among: drives) == .ask)
    }
}

extension View {
    /// Asks once whether to trust a new server. Trust keeps the key, then carries on.
    func trustingServer(_ pending: Binding<PendingTrust?>, trust: @escaping (RemoteEngine.HostKey) -> Void) -> some View {
        alert(
            "Trust this server?",
            isPresented: Binding(get: { pending.wrappedValue != nil }, set: { if !$0 { pending.wrappedValue = nil } }),
            presenting: pending.wrappedValue
        ) { asked in
            Button("Trust") {
                trust(asked.key)
                asked.resume()
            }
            Button("Cancel", role: .cancel) {}
        } message: { asked in
            Text("This is the first time CloudAccess connects to \(asked.host). Its identity is \(asked.key.fingerprint). Check it matches the one your server shows, then trust it.")
        }
    }
}
