// Apache 2 license - developer@infinitecontext.com

import Foundation

/// What to do about a drive whose record and macOS domain disagree, for example after a crash
/// halfway through adding or removing it. Nothing here deletes a domain on its own.
public enum DriveRepair: Equatable, Sendable {
    /// A saved drive lost its domain, so it's registered again.
    case register(UUID)
    /// Adding got as far as the domain, so it's finished.
    case activate(UUID)
    /// Adding never reached a domain, so the record goes.
    case forget(UUID)
    /// Removal didn't finish, so it runs again.
    case finishRemoving(UUID)
    /// A domain with no record: kept, and shown as needing attention.
    case reportUnknownDomain(String)

    /// - Parameters:
    ///   - drives: Each saved drive and its state.
    ///   - domains: The identifiers macOS has registered.
    public static func plan(
        drives: [(id: UUID, lifecycle: Connection.Lifecycle)], domains: Set<String>
    ) -> [DriveRepair] {
        var actions: [DriveRepair] = []
        var known = Set<String>()
        for drive in drives {
            let identifier = drive.id.uuidString
            known.insert(identifier)
            let hasDomain = domains.contains(identifier)
            switch (drive.lifecycle, hasDomain) {
            case (.active, true):
                break
            case (.active, false):
                actions.append(.register(drive.id))
            case (.adding, true):
                actions.append(.activate(drive.id))
            case (.adding, false):
                actions.append(.forget(drive.id))
            case (.removing, _):
                actions.append(.finishRemoving(drive.id))
            }
        }
        for domain in domains.subtracting(known).sorted() {
            actions.append(.reportUnknownDomain(domain))
        }
        return actions
    }
}
