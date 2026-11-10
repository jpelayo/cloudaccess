// Apache 2 license - developer@infinitecontext.com

import Foundation

/// Why an encrypted drive can't be opened. Any of these stops all reads and writes, so a
/// mistake can never write files with a second key.
public enum VaultProblem: String, Sendable {
    case wrongPassword
    /// The folder has files but no vault marker.
    case missing
    /// The folder is empty and creating a vault wasn't requested.
    case notCreated
    /// The folder holds a different vault from the one this drive used.
    case mismatch
    /// The marker is older than the one this device last saw.
    case rollback
    /// A password change retired this vault.
    case retired
    /// The vault needs a newer version of the app.
    case unsupported
    case malformed
    /// The folder holds a vault, but the drive was set up as plain.
    case encrypted
}

/// What's on this Mac instead of a plain file.
public enum LocalKind: String, Sendable {
    case folder
    /// A folder that Finder shows as one document.
    case package
    case link
    case other
}

/// Why a file didn't go, and what to do about it, in a person's words. What it tried and when
/// isn't enough: someone has to be able to act on this. It's kept as two lines in one column.
public struct FileProblem: Equatable, Sendable {
    public var cause: String
    public var fix: String

    public init(cause: String, fix: String) {
        self.cause = cause
        self.fix = fix
    }

    public init(stored text: String) {
        let parts = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        cause = parts.first.map(String.init) ?? ""
        fix = parts.count > 1 ? String(parts[1]) : ""
    }

    public var stored: String {
        fix.isEmpty ? cause : "\(cause)\n\(fix)"
    }

    /// The problem in the language shown now. It's saved in English, because the extension and
    /// the app can show different languages and diagnostics stay English, so it's translated here,
    /// as it's shown. A server's own words, which no table knows, stay as they were.
    public var localized: FileProblem {
        FileProblem(cause: Self.shown(cause), fix: Words.shown(fix))
    }

    /// The sync store puts this in front of a failure it stops retrying.
    static var stoppedPrefix: Regex<(Substring, Substring, Substring)> {
        /^Stopped trying after (\d+) failures\. (.*)$/
    }

    private static func shown(_ cause: String) -> String {
        if let stopped = cause.wholeMatch(of: stoppedPrefix), let count = Int(stopped.output.1) {
            return Words.format("Stopped trying after %lld failures.", count) + " " + Words.shown(String(stopped.output.2))
        }
        return Words.shown(cause)
    }
}

/// A failure from a server, independent of the protocol that produced it.
public enum RemoteError: Error, Equatable, Sendable {
    case notFound(RemotePath)
    case alreadyExists(RemotePath)
    /// The folder that should contain this path does not exist on the server.
    case parentMissing(RemotePath)
    case forbidden(RemotePath)
    case locked(RemotePath)
    /// The item changed on the server since it was last read.
    case versionMismatch(RemotePath)
    /// The name won't fit on the server once it's encrypted.
    case nameTooLong(RemotePath)
    /// The name is reserved for the drive's own use.
    case reservedName(String)
    /// What's on this Mac isn't a plain file, so it can't go up as one. Nothing was sent.
    case notAPlainFile(RemotePath, LocalKind)
    /// This Mac couldn't read the file. The server had nothing to do with it.
    case unreadableHere(RemotePath, String)
    /// The drive is read-only.
    case readOnly
    /// Something went wrong with this item that has no more specific meaning.
    case failed(RemotePath, String)
    /// A folder ran out of time on a server that's still answering. That's this folder's problem,
    /// so it never takes the drive offline.
    case tooSlow(RemotePath)
    /// The server refuses files this large.
    case tooLarge(RemotePath)
    /// A folder holds more items than the iPhone's Files extension can list in the memory iOS
    /// gives it. It's refused whole, never listed in part.
    case tooManyItems(RemotePath)
    case cancelled

    case unauthorized
    case insufficientStorage
    case unreachable(String)
    case server(status: Int)
    case vault(VaultProblem)
    /// An SFTP server's key hasn't been confirmed yet.
    case hostKeyUnknown
    /// An SFTP server's key no longer matches the one confirmed at setup.
    case hostKeyChanged
    /// The server lacks something safe saving depends on.
    case unsupportedServer(String)

    /// What a failure applies to, which decides where the user sees it.
    public enum Scope: Sendable {
        /// One file or folder failed. Show it on that item; the connection stays healthy.
        case item
        /// The whole connection is affected. Only this may turn the menu bar cloud gray.
        case connection
    }

    public var scope: Scope {
        switch self {
        case .notFound, .alreadyExists, .parentMissing, .forbidden, .locked,
             .versionMismatch, .nameTooLong, .reservedName, .notAPlainFile, .unreadableHere,
             .readOnly, .failed, .tooSlow, .tooLarge, .tooManyItems, .cancelled:
            return .item
        case .unauthorized, .insufficientStorage, .unreachable, .server, .vault,
             .hostKeyUnknown, .hostKeyChanged, .unsupportedServer:
            return .connection
        }
    }

    /// Whether trying again later can succeed without the user changing anything.
    public var isRetryable: Bool {
        switch self {
        case .unreachable, .locked, .insufficientStorage, .tooSlow:
            return true
        case .server(let status):
            return status >= 500 || status == Self.tooManyRequests
        default:
            return false
        }
    }

    /// The server wants fewer requests for a while.
    public static let tooManyRequests = 429

    /// A few words for a drive's row, when a person has to act, in the language shown. Nil means it
    /// can come back by itself, so "offline" says enough.
    public var attentionLabel: String? {
        switch self {
        case .unauthorized: Words.text("sign-in refused")
        case .vault(.wrongPassword): Words.text("wrong encryption password")
        case .vault(.retired): Words.text("retired")
        case .vault: Words.text("needs attention")
        case .hostKeyUnknown, .hostKeyChanged: Words.text("server identity changed")
        case .unsupportedServer: Words.text("server not supported")
        default: nil
        }
    }

    /// Whether failing this way over and over says something about the file, so it can stop being
    /// tried. A problem the whole drive has shows on the drive and clears there.
    public var canHoldAFile: Bool {
        switch self {
        case .notFound, .alreadyExists, .parentMissing, .forbidden, .locked, .failed, .tooSlow,
             .tooLarge, .unreachable, .server, .unreadableHere, .nameTooLong, .reservedName,
             .notAPlainFile:
            return true
        case .cancelled, .versionMismatch, .readOnly, .unauthorized, .insufficientStorage, .vault,
             .hostKeyUnknown, .hostKeyChanged, .unsupportedServer, .tooManyItems:
            return false
        }
    }

    /// Whether this can't go to the server as it is, however often it's tried. A folder isn't one:
    /// it may be a package macOS hasn't flattened, so it waits where a person can see it.
    public var canNeverBeSent: Bool {
        switch self {
        case .nameTooLong, .reservedName:
            return true
        case .notAPlainFile(_, let kind):
            return kind == .link || kind == .other
        default:
            return false
        }
    }

    private static let persists = "If it keeps failing, export Diagnostics from Settings."

    /// Why this happened and what to do, for a file that didn't go. It's saved, so it's English:
    /// `FileProblem.localized` translates it when it's shown.
    public var problem: FileProblem {
        switch self {
        case .notAPlainFile(_, let kind):
            return Self.problem(with: kind)
        case .unreadableHere:
            return FileProblem(
                cause: englishDescription,
                fix: "Check that it opens on this Mac, close any app using it, then press Try Again.")
        case .nameTooLong:
            return FileProblem(
                cause: "This name is too long for an encrypted drive.",
                fix: "Shorten it in Finder. It should then upload by itself.")
        case .reservedName(let name):
            return FileProblem(
                cause: "\(name) is a name the drive keeps for itself.", fix: "Rename it in Finder.")
        case .forbidden:
            return FileProblem(
                cause: "The server refused to store this file.",
                fix: "Check that your account can write to this folder, then press Try Again.")
        case .parentMissing:
            return FileProblem(
                cause: "The folder for this file isn't on the server.",
                fix: "Check that the folder still exists, then press Try Again.")
        case .locked:
            return FileProblem(
                cause: "Another device is saving this file, or a save was interrupted.",
                fix: "Nothing to do. This clears by itself within 10 minutes.")
        case .unreachable(let message):
            let said = message.components(separatedBy: ": ").last ?? ""
            return FileProblem(
                cause: "The connection failed while sending this file\(said.isEmpty ? "" : " (\(said))").",
                fix: "Check your network, then press Try Again. \(Self.persists)")
        case .server(Self.tooManyRequests):
            return FileProblem(
                cause: "The server asked for fewer requests for a while.",
                fix: "Nothing to do. This carries on by itself.")
        case .server(let status):
            return FileProblem(
                cause: "The server reported an error (\(status)). That's a problem on the server's side.",
                fix: "Press Try Again later. If it keeps happening, check with your server's provider.")
        case .alreadyExists:
            return FileProblem(
                cause: "Another file or folder on the server already has this name.",
                fix: "Rename one of them in Finder.")
        case .tooLarge:
            return FileProblem(
                cause: "The server refuses files this large, so it wasn't saved there. It's still on this Mac.",
                fix: "Check the server's upload limit, or keep this file somewhere else.")
        case .tooSlow:
            return FileProblem(
                cause: "The server took too long to answer.",
                fix: "It may be busy, so press Try Again later.")
        case .tooManyItems:
            return FileProblem(
                cause: "This folder has too many items for the Files app to show.",
                fix: "Open it in CloudWanderer instead.")
        case .insufficientStorage:
            return FileProblem(
                cause: "The server is out of space.", fix: "Free some space there, then press Try Again.")
        case .readOnly:
            return FileProblem(
                cause: "This drive is read-only.", fix: "Turn off Read-only under Advanced to change it.")
        default:
            return FileProblem(
                cause: englishDescription, fix: "Press Try Again. \(Self.persists)")
        }
    }

    private static func problem(with kind: LocalKind) -> FileProblem {
        switch kind {
        case .folder, .package:
            return FileProblem(
                cause: "macOS handed this over as a folder, not as one file, so nothing was sent. It's safe on this Mac.",
                fix: "Press Try Again. \(persists)")
        case .link:
            return FileProblem(
                cause: "This is a link, and CloudAccess doesn't upload links. Nothing was sent.",
                fix: "To have it on the server, replace the link with a copy of the real file.")
        case .other:
            return FileProblem(
                cause: "This isn't a regular file, so nothing was sent.",
                fix: "Copy what it holds into a normal file if you need it on the server.")
        }
    }

    /// Whether a folder that can't be listed should show what's known, instead of an error.
    public var leavesListingAlone: Bool {
        switch self {
        case .tooSlow, .tooManyItems: return true
        default: return scope == .connection
        }
    }

    /// Whether this belongs on the file in the failed list. Connection problems show on the
    /// drive, but a full server stops one file at a time. A version mismatch isn't a failure:
    /// macOS sorts that out itself.
    public var belongsOnAFile: Bool {
        switch self {
        case .cancelled, .versionMismatch: false
        case .insufficientStorage: true
        default: scope == .item
        }
    }
}

extension RemoteError: WordedError {
    /// The failure in the language the app shows. The engine's own words, such as a server's
    /// message, are translated when the table knows them, and otherwise shown as they came.
    public var errorDescription: String? {
        wording.shown
    }

    /// The failure in English, for what's saved, logged and exported.
    public var englishDescription: String {
        wording.english
    }

    private var wording: Wording {
        switch self {
        case .notFound(let path): Wording("%@ isn't on the server.", "\(path)")
        case .alreadyExists(let path): Wording("%@ already exists.", "\(path)")
        case .parentMissing(let path): Wording("The folder for %@ isn't on the server.", "\(path)")
        case .forbidden(let path): Wording("The server doesn't allow access to %@.", "\(path)")
        case .locked(let path): Wording("Another device is saving %@.", "\(path)")
        case .versionMismatch(let path): Wording("%@ changed on the server.", "\(path)")
        case .nameTooLong: Wording("This name is too long for an encrypted drive. Shorten it in Finder.")
        case .reservedName(let name): Wording("%@ is a name the drive keeps for itself.", name)
        case .notAPlainFile: Wording(problem.cause)
        case .unreadableHere(_, let reason): Wording("This Mac couldn't read the file (%@), so nothing was sent.", reason)
        case .readOnly: Wording("This drive is read-only.")
        case .failed(_, let message): Wording(message)
        case .tooSlow(let path): Wording("%@ took too long to list. The server may be busy.", "\(path)")
        case .tooLarge(let path): Wording("The server refuses files as large as %@.", "\(path)")
        case .tooManyItems(let path): Wording("%@ has too many items for the Files app. Open it in CloudWanderer.", "\(path)")
        case .cancelled: Wording("Cancelled.")
        case .unauthorized: Wording("The server refused the username or password.")
        case .insufficientStorage: Wording("The server is out of space.")
        case .unreachable: Wording("The server can't be reached.")
        case .server(let status): Wording("The server reported an error (%lld).", status)
        case .vault(.wrongPassword): Wording("That encryption password is wrong.")
        case .vault(.missing): Wording("This folder already has files in it, and an encrypted drive needs an empty one. Choose or create another folder.")
        case .vault(.notCreated): Wording("This folder has no encrypted drive yet.")
        case .vault(.mismatch): Wording("This folder holds a different encrypted drive.")
        case .vault(.rollback): Wording("This folder holds an older copy of the encrypted drive.")
        case .vault(.retired): Wording("This encrypted drive was retired by a password change.")
        case .vault(.unsupported): Wording("This encrypted drive needs a newer version of CloudAccess.")
        case .vault(.malformed): Wording("This encrypted drive's details are damaged.")
        case .vault(.encrypted): Wording("This folder is an encrypted drive. Turn on encryption and enter its password.")
        case .hostKeyUnknown: Wording("This server's identity hasn't been confirmed.")
        case .hostKeyChanged: Wording("This server's identity has changed. It may have been reinstalled, or it may not be your server.")
        case .unsupportedServer(let message): Wording(message)
        }
    }
}
