// Apache 2 license - developer@infinitecontext.com

/// What a file macOS says is waiting to sync is called. macOS can keep an entry with no name in
/// that list long after its file is gone, and a disk allows no empty name, so an entry nobody can
/// name is no file: listing it would show a blank row, and counting it would say an upload waits
/// forever.
public enum PendingName {
    /// - Parameters:
    ///   - reported: The name macOS gives.
    ///   - recorded: The name in the drive's own records, if it has the item.
    /// - Returns: Nil when neither has a name.
    public static func shown(reported: String, recorded: String?) -> String? {
        if !reported.isEmpty { return reported }
        guard let recorded, !recorded.isEmpty else { return nil }
        return recorded
    }
}
