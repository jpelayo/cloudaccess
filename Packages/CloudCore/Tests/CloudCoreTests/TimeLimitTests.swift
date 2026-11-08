// Apache 2 license - developer@infinitecontext.com

import CloudCore
import Foundation
import Testing

@Suite struct TimeLimitTests {
    private struct Refused: Error {}

    @Test func anAnswerInTimeIsReturned() async throws {
        let value = try await withinTime(.seconds(5)) { 7 }
        #expect(value == 7)
    }

    @Test func anErrorInTimeIsPassedOn() async {
        await #expect(throws: Refused.self) {
            try await withinTime(.seconds(5)) { () -> Int in throw Refused() }
        }
    }

    /// The call this guards can't be cancelled, so the wait has to end without it.
    @Test func workThatNeverAnswersDoesntHoldTheCallerUp() async {
        let started = ContinuousClock.now
        await #expect(throws: TimedOut.self) {
            try await withinTime(.milliseconds(50)) { () -> Int in
                await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
                return 1
            }
        }
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    /// Thousands of these run in a day, so a quick answer must not leave a timer behind that
    /// answers a second time.
    @Test func aLateAnswerIsDropped() async throws {
        for _ in 0..<200 {
            let value = try await withinTime(.milliseconds(1)) { 3 }
            #expect(value == 3)
        }
    }
}
