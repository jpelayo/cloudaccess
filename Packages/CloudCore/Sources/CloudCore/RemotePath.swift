// Apache 2 license - developer@infinitecontext.com

import Foundation

/// An absolute, normalised path on a drive, relative to the drive's root.
///
/// Always starts with `/`, never ends with `/` (except the root), and never contains
/// `.` or `..`.
public struct RemotePath: Hashable, Sendable, Codable, CustomStringConvertible {
    public let components: [String]

    public static let root = RemotePath(validated: [])

    /// Paths compare by their bytes. Swift calls two Unicode spellings of a name equal, but a
    /// server holds them as two files, and they must never pass for one.
    public static func == (left: RemotePath, right: RemotePath) -> Bool {
        left.components.count == right.components.count
            && zip(left.components, right.components).allSatisfy { $0.utf8.elementsEqual($1.utf8) }
    }

    public func hash(into hasher: inout Hasher) {
        for component in components {
            hasher.combine(Array(component.utf8))
        }
    }

    private init(validated components: [String]) {
        self.components = components
    }

    /// Returns `nil` if the string contains a `.` or `..` component.
    public init?(_ string: String) {
        let parts = string.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.allSatisfy(Self.isValidName) else { return nil }
        self.components = parts
    }

    public static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }

    /// Whether a name belongs to the drive itself, and can't be used for a file.
    public static func isReservedName(_ name: String) -> Bool {
        name == ".cloudmount" || name.hasPrefix(".cm-")
    }

    public var isRoot: Bool { components.isEmpty }

    /// The last component, or an empty string for the root.
    public var name: String { components.last ?? "" }

    /// The containing folder, or `nil` for the root.
    public var parent: RemotePath? {
        isRoot ? nil : RemotePath(validated: Array(components.dropLast()))
    }

    /// Returns `nil` if `name` is not a single valid path component.
    public func appending(_ name: String) -> RemotePath? {
        guard Self.isValidName(name) else { return nil }
        return RemotePath(validated: components + [name])
    }

    public var description: String { "/" + components.joined(separator: "/") }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let path = RemotePath(raw) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Invalid remote path: \(raw)"))
        }
        self = path
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}
