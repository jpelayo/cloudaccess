// Apache 2 license - developer@infinitecontext.com

import Foundation

/// How an edit of a drive's details is applied on the iPhone, following the Mac's rules. A new
/// name or sign-in changes the drive where it is. A new server, folder or account makes a new
/// drive, because the downloads, listings and Files location kept for it describe the old place.
public enum DriveEdit {
    public enum Change: Equatable, Sendable {
        case nothing
        /// The same drive, under the same ID. When it needs a check, it's connected with the new
        /// details before anything is saved.
        case inPlace(Connection, needsCheck: Bool)
        /// A new drive with a new ID and the same name. It's always connected first.
        case move(Connection)
        case refused(String)
    }

    /// What two drives on one device can't share. Two drives on one folder would be two sets of
    /// copies of the same files, and two with one name couldn't be told apart.
    public enum Clash: Equatable, Sendable {
        case name
        case place

        public var reason: String {
            switch self {
            case .name: Words.text("Another drive is called that.")
            case .place: Words.text("This server folder is already a drive here.")
            }
        }
    }

    // Refusals are shown straight away and never saved, so they're in the language shown.
    public static var noName: String { Words.text("The drive needs a name.") }
    public static var badAddress: String { Words.text("That address isn't valid.") }
    public static var unsafeNeedsSFTP: String {
        Words.text("Only SFTP drives can use Unsafe mode. Choose Safe or Read-only under Advanced first.")
    }

    /// Why a drive can't be saved with its mode, or nil if it can. Unsafe needs SFTP's one-step
    /// replace, and quietly falling back to Safe would write the folder a person chose to avoid.
    public static func modeRefusal(for drive: Connection) -> String? {
        DriveMode.available(for: drive.endpoint).contains(drive.settings.mode) ? nil : unsafeNeedsSFTP
    }

    /// Whether a drive would clash with another one already on this device. A drive never clashes
    /// with itself.
    public static func clash(_ drive: Connection, among others: [Connection]) -> Clash? {
        for other in others where other.id != drive.id {
            if other.displayName == drive.displayName {
                return .name
            }
            if !other.requiresNewDrive(comparedTo: drive) {
                return .place
            }
        }
        return nil
    }

    /// What saving these fields would do to a saved drive.
    /// - Parameter others: Every drive on this device, which may include the saved one.
    public static func change(
        from saved: Connection, form: ConnectionForm, signIn: SignInEdit, among others: [Connection]
    ) -> Change {
        guard !form.name.trimmingCharacters(in: .whitespaces).isEmpty else { return .refused(noName) }
        guard let edited = form.applied(to: saved) else { return .refused(badAddress) }
        #if DEBUG
        guard edited.isTestDrive else {
            return .refused(Words.format(
                "This test build only connects to a folder named %@.", Connection.testFolderName))
        }
        #endif
        if let clash = clash(edited, among: others) {
            return .refused(clash.reason)
        }
        if let refusal = modeRefusal(for: edited) {
            return .refused(refusal)
        }
        if edited.requiresNewDrive(comparedTo: saved) {
            var moved = edited
            moved.id = UUID()
            return .move(moved)
        }
        var renamedOnly = edited
        renamedOnly.displayName = saved.displayName
        // Anything besides the name, such as a host respelled so its pins were dropped, means
        // connecting again, so the drive is never saved with less than it had.
        let isOnlyRenamed = renamedOnly == saved
        if edited == saved, signIn.isEmpty {
            return .nothing
        }
        return .inPlace(edited, needsCheck: !signIn.isEmpty || !isOnlyRenamed)
    }
}
