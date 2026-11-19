// Apache 2 license - developer@infinitecontext.com

/// The short form an encrypted drive keeps for a name too long for it, as the engine makes it
/// (Engine/longnames.go): the start of the name, a tilde, ten characters of a hash, and the
/// extension. Where the full name can't be kept beside it, the item takes this name everywhere.
public enum ShortName {
    /// Whether a name is in short form. Only a name the server returned is ever asked about.
    public static func isShortForm(_ name: String) -> Bool {
        name.wholeMatch(of: /.*~[a-z2-7]{10}(\.[^.\/~]{1,15})?/) != nil
    }
}
