// Apache 2 license - developer@infinitecontext.com

import Foundation

/// A key chosen in a file panel, which only gives access for as long as it's being read. Both
/// apps read keys this way.
public struct PrivateKeyFile: Sendable {
    public let text: String
    public let name: String

    public init(_ result: Result<URL, Error>) throws {
        let url = try result.get()
        let isAllowed = url.startAccessingSecurityScopedResource()
        defer {
            if isAllowed { url.stopAccessingSecurityScopedResource() }
        }
        text = try String(contentsOf: url, encoding: .utf8)
        name = url.lastPathComponent
    }
}
