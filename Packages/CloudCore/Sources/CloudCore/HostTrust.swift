// Apache 2 license - developer@infinitecontext.com

/// Whether a new SFTP server's key has to be put to a person. Trust is only ever given by a
/// person: a key is taken without asking only when it's exactly one already trusted for the same
/// server, by another drive on this device. A key that changed is never decided here: that one
/// goes to the drive's own review, because it can mean someone is in the way.
public enum HostTrust {
    public enum Decision: Equatable, Sendable {
        case alreadyTrusted
        case ask
    }

    /// - Parameters:
    ///   - offered: The key the server just presented, as the engine gives it.
    ///   - among: Every drive saved on this device.
    public static func decide(offered: String, host: String, port: Int, among drives: [Connection]) -> Decision {
        let wanted = host.lowercased()
        let isTrusted = drives.contains { drive in
            guard case .sftp(let savedHost, let savedPort) = drive.endpoint, let saved = drive.hostKey else {
                return false
            }
            return savedHost.lowercased() == wanted && savedPort == port && saved == offered
        }
        return isTrusted ? .alreadyTrusted : .ask
    }
}
