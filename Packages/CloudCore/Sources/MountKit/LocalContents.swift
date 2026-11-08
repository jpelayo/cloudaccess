// Apache 2 license - developer@infinitecontext.com

import CloudCore
import Foundation

/// What's really at a path macOS hands over, whatever its name or type says. Nothing goes to the
/// server until this has looked, because a document can be a folder, and the name can't tell.
public enum LocalContents: Equatable, Sendable {
    case file(size: Int64, modified: Date?)
    case not(LocalKind)
    case unreadable(String)

    /// Looks at the path itself, without following a link, then proves the file can be read.
    public static func inspect(_ url: URL) -> LocalContents {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            return .unreadable(reason(error))
        }
        switch attributes[.type] as? FileAttributeType {
        case .typeRegular:
            break
        case .typeDirectory:
            let isPackage = (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage == true
            return .not(isPackage ? .package : .folder)
        case .typeSymbolicLink:
            return .not(.link)
        default:
            return .not(.other)
        }
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            _ = try handle.read(upToCount: 1)
        } catch {
            return .unreadable(reason(error))
        }
        return .file(
            size: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
            modified: attributes[.modificationDate] as? Date)
    }

    private static func reason(_ error: Error) -> String {
        let plain = error as NSError
        let underlying = plain.userInfo[NSUnderlyingErrorKey] as? NSError
        return (underlying ?? plain).localizedDescription
    }
}
