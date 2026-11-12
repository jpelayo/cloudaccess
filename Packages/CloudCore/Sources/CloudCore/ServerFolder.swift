// Apache 2 license - developer@infinitecontext.com

import Foundation

/// A drive's folder on the server, tidied into the one form each protocol stores, however a
/// person typed it, pasted it, or another device exported it.
///
/// On SFTP the two readings of a folder are different places, and they stay different:
/// - `Documents`, `~/Documents` and `/~/Documents` are Documents in the login's home folder,
///   stored as `Documents`. Blank, `~` and `~/` are the home folder itself, stored as `""`.
/// - `/Documents` is Documents from the server's top, and `/` is the top itself.
///
/// On WebDAV the folder is part of the address, so `Documents` and `/Documents` are one place,
/// stored as `/Documents`, and a leading `~` means nothing there and is dropped.
///
/// Both forms trim the space around the whole value, collapse `//`, drop a trailing `/`, and
/// refuse `.` and `..`, which would make one folder read as another.
public enum ServerFolder {
    /// The SFTP form, or nil for a folder that can't be one.
    public static func sftp(_ typed: String) -> String? {
        var text = Substring(typed.trimmingCharacters(in: .whitespacesAndNewlines))
        let fromTop: Bool
        if let rest = droppingHome(from: text) {
            text = rest
            fromTop = false
        } else {
            fromTop = text.hasPrefix("/")
        }
        guard let parts = segments(of: text) else { return nil }
        let joined = parts.joined(separator: "/")
        return fromTop ? "/" + joined : joined
    }

    /// The WebDAV form, as a URL path: blank, or starting with `/`. Nil for a folder that can't
    /// be one.
    public static func webDAV(_ typed: String) -> String? {
        var text = Substring(typed.trimmingCharacters(in: .whitespacesAndNewlines))
        if let rest = droppingHome(from: text) {
            text = rest
        }
        guard let parts = segments(of: text) else { return nil }
        return parts.isEmpty ? "" : "/" + parts.joined(separator: "/")
    }

    /// The form a protocol stores, chosen by its endpoint.
    public static func tidied(_ typed: String, for endpoint: Connection.Endpoint) -> String? {
        switch endpoint {
        case .sftp: sftp(typed)
        case .webDAV: webDAV(typed)
        case .localFolder: typed
        }
    }

    /// `~`, `~/x`, `/~` and `/~/x` are the home folder and what's inside it. `~name` is another
    /// person's home on some servers, and nothing here can mean that, so it's left as typed.
    private static func droppingHome(from text: Substring) -> Substring? {
        for prefix in ["/~", "~"] where text.hasPrefix(prefix) {
            let rest = text.dropFirst(prefix.count)
            if rest.isEmpty || rest.hasPrefix("/") {
                return rest
            }
        }
        return nil
    }

    /// The folder's names, with empty ones from `//` or a trailing `/` dropped. Nil if any is
    /// `.` or `..`.
    private static func segments(of text: Substring) -> [Substring]? {
        let parts = text.split(separator: "/", omittingEmptySubsequences: true)
        guard !parts.contains(where: { $0 == "." || $0 == ".." }) else { return nil }
        return parts
    }

    /// Why a folder was refused, in the language shown.
    public static var refusal: String {
        Words.text("A folder can't contain . or .. in its path.")
    }

    /// Where an SFTP folder is, in plain words in the language shown, such as "Documents, in the
    /// home folder". Nil on WebDAV, where the address already says it.
    public static func shownPlace(of connection: Connection) -> String? {
        guard case .sftp = connection.endpoint else { return nil }
        let folder = sftp(connection.rootPath) ?? connection.rootPath
        if folder.isEmpty {
            return Words.text("The home folder")
        }
        if folder == "/" {
            return Words.text("The top of the server")
        }
        if folder.hasPrefix("/") {
            return Words.format("%@, from the top of the server", String(folder.dropFirst()))
        }
        return Words.format("%@, in the home folder", folder)
    }

    /// Why the folder asked for wasn't used, when the other reading of it is there, in the
    /// language shown.
    public static func missingFolder(_ folder: String, other: String) -> String {
        let tidy = sftp(folder) ?? folder
        if tidy.hasPrefix("/") {
            return Words.format("There's no %1$@ at the top of the server, but the home folder has %2$@.", tidy, other)
        }
        return Words.format("There's no %1$@ in the home folder, but the top of the server has %2$@.", tidy, other)
    }

    /// A folder as a person reads it on SFTP: `~/Documents` in the home folder, `/Documents`
    /// from the server's top.
    public static func shown(_ folder: String) -> String {
        let tidy = sftp(folder) ?? folder
        return tidy.isEmpty ? "~" : tidy.hasPrefix("/") ? tidy : "~/" + tidy
    }

    /// The same folder read the other way on SFTP, to offer when the one typed isn't there:
    /// `/Documents` for `Documents`, and the reverse. Nil when there's no other reading.
    public static func otherReading(of folder: String) -> String? {
        guard let tidy = sftp(folder), !tidy.isEmpty, tidy != "/" else { return nil }
        return tidy.hasPrefix("/") ? String(tidy.dropFirst()) : "/" + tidy
    }
}
