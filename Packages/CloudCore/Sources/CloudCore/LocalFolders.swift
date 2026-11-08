// Apache 2 license - developer@infinitecontext.com

import Foundation

/// The folders under a drive's root that really hold something on this device.
public enum LocalFolders {
    /// Nearest first, because macOS works down a tree. Dataless folders are left out: nothing in
    /// them is on this device, and reading one would make macOS fetch it from the server.
    /// - Parameter limit: A guard against an enormous tree. The rest wait for macOS's own import.
    public static func under(_ root: URL, limit: Int) -> [URL] {
        var found = [root]
        var next = 0
        while next < found.count {
            let children = (try? FileManager.default.contentsOfDirectory(
                at: found[next], includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])) ?? []
            next += 1
            for child in children where isLocalFolder(child) {
                guard found.count < limit else { return found }
                found.append(child)
            }
        }
        return found
    }

    private static func isLocalFolder(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true, values.isSymbolicLink != true
        else { return false }
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_flags & UInt32(SF_DATALESS) == 0
    }
}
