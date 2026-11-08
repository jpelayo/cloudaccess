// Apache 2 license - developer@infinitecontext.com

import Foundation

/// Moves one drive's password from the keychain group it was saved in to the one the iPhone's
/// Files extension can read. A password exists only on this phone, so the old copy goes only
/// once the new one has read back the same, and anything uncertain leaves it where it was.
public enum PasswordMove {
    /// What a read found.
    public enum Lookup: Equatable, Sendable {
        case found(Data)
        case missing
        /// Something stopped the read, such as a locked iPhone, so it says nothing either way.
        case failed
    }

    public enum Outcome: Equatable, Sendable {
        case moved
        /// The new place has it already. A copy left in the old place is gone now.
        case alreadyHere
        case nothingThere
        case keptWhereItWas
    }

    public static func run(
        readNew: () -> Lookup,
        readOld: () -> Lookup,
        saveNew: (Data) -> Bool,
        deleteNew: () -> Void,
        deleteOld: () -> Void
    ) -> Outcome {
        switch readNew() {
        case .found:
            // Only this store saves there, so whatever's there is newer than what was left behind.
            if case .found = readOld() {
                deleteOld()
            }
            return .alreadyHere
        case .failed:
            // A copy could overwrite a newer password that just couldn't be read.
            return .keptWhereItWas
        case .missing:
            break
        }
        let old: Data
        switch readOld() {
        case .found(let data): old = data
        case .missing: return .nothingThere
        case .failed: return .keptWhereItWas
        }
        guard saveNew(old) else { return .keptWhereItWas }
        switch readNew() {
        case .found(let back) where back == old:
            deleteOld()
            return .moved
        case .found:
            // Reads would find this first, in place of the password still in the old place.
            deleteNew()
            return .keptWhereItWas
        case .missing, .failed:
            return .keptWhereItWas
        }
    }
}
