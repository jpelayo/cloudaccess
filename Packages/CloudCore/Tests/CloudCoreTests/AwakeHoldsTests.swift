// Apache 2 license - developer@infinitecontext.com

@testable import CloudCore
import Foundation
import Testing

@Suite struct AwakeHoldsTests {
    @Test func nothingIsHeldAtTheStart() {
        #expect(!AwakeHolds().isHeld)
    }

    @Test func oneDownloadKeepsTheScreenOnUntilItEnds() {
        var holds = AwakeHolds()
        let download = holds.hold()
        #expect(holds.isHeld)
        holds.release(download)
        #expect(!holds.isHeld)
    }

    @Test func theScreenStaysOnUntilTheLastDownloadEnds() {
        var holds = AwakeHolds()
        let first = holds.hold()
        let second = holds.hold()
        holds.release(first)
        #expect(holds.isHeld)
        holds.release(second)
        #expect(!holds.isHeld)
    }

    @Test func endingTwiceDoesntEndAnotherDownload() {
        var holds = AwakeHolds()
        let first = holds.hold()
        _ = holds.hold()
        holds.release(first)
        holds.release(first)
        #expect(holds.isHeld)
    }

    @Test func anUnknownHoldChangesNothing() {
        var holds = AwakeHolds()
        _ = holds.hold()
        holds.release(UUID())
        #expect(holds.isHeld)
    }
}
