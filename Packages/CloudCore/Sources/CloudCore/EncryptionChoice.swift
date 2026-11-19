// Apache 2 license - developer@infinitecontext.com

/// What a server folder holds, as far as choosing encryption goes. `.cloudmount` doesn't count.
public enum FolderContents: Equatable, Sendable {
    /// Nothing yet, or no folder yet: it's made on connecting.
    case empty
    /// Files that aren't encrypted, which an encrypted drive can't share a folder with.
    case plainFiles
    /// An encrypted drive, which only its password opens.
    case encryptedDrive
}

/// What the encryption switch in an add form may be, once the folder is known. Both apps decide
/// by this, so they offer the same thing in the same words, before Connect fails.
public enum EncryptionChoice: Equatable, Sendable {
    /// Either is possible, or the folder hasn't been checked yet.
    case free
    /// Only plain is possible, for this reason, in the language shown.
    case lockedOff(String)
    /// Only encrypted is possible, for this reason, in the language shown.
    case lockedOn(String)

    public static func `for`(_ contents: FolderContents?, device: DeviceKind) -> EncryptionChoice {
        switch contents {
        case nil:
            return .free
        case .plainFiles?:
            return .lockedOff(Words.text("This folder already has files that aren't encrypted, so it can't become an encrypted drive."))
        case .encryptedDrive?:
            return .lockedOn(Words.text("This folder is already an encrypted drive. Enter its encryption password to join it."))
        case .empty?:
            // CloudWanderer joins encrypted drives but never makes one.
            guard device == .iPhone else { return .free }
            return .lockedOff(Words.text("CloudWanderer only joins encrypted drives made with CloudAccess, and this folder isn't one."))
        }
    }

    /// The only value the switch may have, or nil when it's free.
    public var lockedValue: Bool? {
        switch self {
        case .free: nil
        case .lockedOff: false
        case .lockedOn: true
        }
    }

    /// Why the switch is locked, or nil when it's free.
    public var reason: String? {
        switch self {
        case .free: nil
        case .lockedOff(let reason), .lockedOn(let reason): reason
        }
    }
}
