// Apache 2 license - developer@infinitecontext.com

import Foundation

/// Which of the iPhone's drives appear in the Files app. Each one there is a File Provider domain
/// whose identifier is the drive's ID, as on the Mac.
public enum FilesLocations {
    /// Why a drive isn't in Files, for the one line the app shows on it.
    public enum Absence: Equatable, Sendable {
        /// Unlocking an encrypted drive runs scrypt, which needs 16 MiB by itself, and iOS stops
        /// the Files extension at about 20 MB.
        case encrypted
        /// A test build shows only test drives there, as it connects only to them.
        case notATestDrive
    }

    /// Why this drive can't be in Files, or nil if it can.
    public static func absence(of connection: Connection) -> Absence? {
        if connection.isEncrypted {
            return .encrypted
        }
        #if DEBUG
        if !connection.isTestDrive {
            return .notATestDrive
        }
        #endif
        return nil
    }

    public static func canShow(_ connection: Connection) -> Bool {
        absence(of: connection) == nil
    }

    /// One drive's place in Files.
    public struct Location: Equatable, Sendable {
        public var id: UUID
        public var name: String

        public init(id: UUID, name: String) {
            self.id = id
            self.name = name
        }
    }

    /// What to change so the Files locations match the drives.
    public struct Plan: Equatable, Sendable {
        public var add: [Location] = []
        /// Locations whose name changed. They're added again under the same identifier, which
        /// Apple says renames them. Removing one first would throw away what it holds.
        public var rename: [Location] = []
        public var remove: [String] = []

        public init() {}
    }

    /// The name each drive shows in Files. Apple refuses a second location with a name already in
    /// use, so drives that share one get their server's name after it, then a number.
    public static func names(for drives: [Connection]) -> [UUID: String] {
        let shown = drives.filter(canShow)
        var names: [UUID: String] = [:]
        let counts = Dictionary(grouping: shown, by: \.displayName).mapValues(\.count)
        var used = Set<String>()
        for drive in shown {
            var name = drive.displayName
            if counts[name, default: 0] > 1, let host = drive.endpoint.host {
                name = "\(name) (\(host))"
            }
            var candidate = name
            var number = 2
            while used.contains(candidate) {
                candidate = "\(name) \(number)"
                number += 1
            }
            used.insert(candidate)
            names[drive.id] = candidate
        }
        return names
    }

    /// What to change so the Files locations match the drives. A location with no drive behind it
    /// is removed: the iPhone only reads, so a location never holds anything that isn't on the
    /// server. That's unlike the Mac, where a location can hold unsent work and is never removed
    /// on a guess.
    /// - Parameters:
    ///   - drives: The drives the app has.
    ///   - locations: Each location Files has now, by identifier, with the name it shows.
    public static func plan(drives: [Connection], locations: [String: String]) -> Plan {
        let names = names(for: drives)
        var plan = Plan()
        for drive in drives {
            guard let name = names[drive.id] else { continue }
            switch locations[drive.id.uuidString] {
            case nil: plan.add.append(Location(id: drive.id, name: name))
            case name: break
            default: plan.rename.append(Location(id: drive.id, name: name))
            }
        }
        let wanted = Set(names.keys.map(\.uuidString))
        plan.remove = Set(locations.keys).subtracting(wanted).sorted()
        return plan
    }
}
