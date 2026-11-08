// Apache 2 license - developer@infinitecontext.com

import CloudCore
import Foundation
import Testing

/// Moving an iPhone password to where the Files extension can read it. A password exists only on
/// the phone, so the old copy goes only once the new one has read back the same.
@Suite struct PasswordMoveTests {
    /// Two keychain groups, and what was done to them, in order.
    private final class Keychain {
        var new: Data?
        var old: Data?
        var newIsUnreadable = false
        var saveFails = false
        /// Saves something other than what it was given, as a damaged write would.
        var saveGarbles = false
        var steps: [String] = []

        init(new: Data? = nil, old: Data? = nil) {
            self.new = new
            self.old = old
        }

        func run() -> PasswordMove.Outcome {
            PasswordMove.run(
                readNew: {
                    steps.append("read new")
                    if newIsUnreadable { return .failed }
                    return new.map(PasswordMove.Lookup.found) ?? .missing
                },
                readOld: {
                    steps.append("read old")
                    return old.map(PasswordMove.Lookup.found) ?? .missing
                },
                saveNew: { data in
                    steps.append("save new")
                    if saveFails { return false }
                    new = saveGarbles ? Data("garbled".utf8) : data
                    return true
                },
                deleteNew: {
                    steps.append("delete new")
                    new = nil
                },
                deleteOld: {
                    steps.append("delete old")
                    old = nil
                })
        }
    }

    private let password = Data(#"{"password":"x"}"#.utf8)

    @Test func theOldCopyGoesOnlyAfterTheNewOneReadsBack() {
        let keychain = Keychain(old: password)
        #expect(keychain.run() == .moved)
        #expect(keychain.new == password)
        #expect(keychain.old == nil)
        #expect(keychain.steps == ["read new", "read old", "save new", "read new", "delete old"])
    }

    @Test func aFailedSaveKeepsTheOldCopy() {
        let keychain = Keychain(old: password)
        keychain.saveFails = true
        #expect(keychain.run() == .keptWhereItWas)
        #expect(keychain.old == password)
        #expect(!keychain.steps.contains("delete old"))
    }

    /// A copy that doesn't read back the same is taken away, so nothing reads it in place of the
    /// password that's still in the old place.
    @Test func aCopyThatReadsBackWrongIsDropped() {
        let keychain = Keychain(old: password)
        keychain.saveGarbles = true
        #expect(keychain.run() == .keptWhereItWas)
        #expect(keychain.old == password)
        #expect(keychain.new == nil)
    }

    /// A password saved since, such as by signing in again, is newer than what's left behind.
    @Test func aLeftoverOldCopyGoesOnceTheNewOneIsThere() {
        let newer = Data(#"{"password":"y"}"#.utf8)
        let keychain = Keychain(new: newer, old: password)
        #expect(keychain.run() == .alreadyHere)
        #expect(keychain.new == newer)
        #expect(keychain.old == nil)
    }

    /// When the new place can't be read, a copy could overwrite a newer password, so nothing moves.
    @Test func anUnreadableNewPlaceTouchesNothing() {
        let keychain = Keychain(old: password)
        keychain.newIsUnreadable = true
        #expect(keychain.run() == .keptWhereItWas)
        #expect(keychain.old == password)
        #expect(keychain.steps == ["read new"])
    }

    @Test func noPasswordMeansNothingToDo() {
        let keychain = Keychain()
        #expect(keychain.run() == .nothingThere)
        #expect(keychain.steps == ["read new", "read old"])
    }

    @Test func aSecondRunChangesNothing() {
        let keychain = Keychain(old: password)
        #expect(keychain.run() == .moved)
        #expect(keychain.run() == .alreadyHere)
        #expect(keychain.new == password)
        #expect(keychain.old == nil)
    }
}
