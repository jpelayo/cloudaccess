// Apache 2 license - developer@infinitecontext.com

@testable import CloudCore
import Testing

@Suite struct PendingNameTests {
    @Test func macOSsNameIsShown() {
        #expect(PendingName.shown(reported: "Notes.txt", recorded: "Old.txt") == "Notes.txt")
    }

    @Test func withNoNameFromMacOSTheDrivesOwnNameIsShown() {
        #expect(PendingName.shown(reported: "", recorded: "Notes.txt") == "Notes.txt")
    }

    @Test func withNoNameAnywhereItIsNoFile() {
        #expect(PendingName.shown(reported: "", recorded: nil) == nil)
        #expect(PendingName.shown(reported: "", recorded: "") == nil)
    }
}
