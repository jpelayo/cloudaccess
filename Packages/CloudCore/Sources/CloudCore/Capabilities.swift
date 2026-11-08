// Apache 2 license - developer@infinitecontext.com

/// What this platform can do. This is the only place platform differences live, so the
/// rest of the code asks a question here rather than checking the operating system.
public struct Capabilities: Sendable {
    public var canMountInFinder: Bool
    public var canPinFolders: Bool
    public var canWrite: Bool

    public static var current: Capabilities {
        #if os(macOS)
        Capabilities(canMountInFinder: true, canPinFolders: true, canWrite: true)
        #else
        Capabilities(canMountInFinder: false, canPinFolders: false, canWrite: false)
        #endif
    }
}
