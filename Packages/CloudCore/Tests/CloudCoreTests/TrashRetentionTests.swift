// Apache 2 license - developer@infinitecontext.com

import CloudCore
import Foundation
import Testing

@Suite struct TrashRetentionTests {
    @Test func theChoicesRunFromShortestToLongest() {
        let seconds = TrashRetention.choices.map(\.seconds)
        #expect(seconds == seconds.sorted())
        #expect(TrashRetention.choices.map(\.label) == [
            "1 minute", "1 hour", "1 day", "7 days", "30 days", "90 days", "1 year",
        ])
    }

    @Test func theDefaultIsAWeekAndOneOfTheChoices() {
        #expect(TrashRetention.defaultSeconds == 7 * 86_400)
        #expect(TrashRetention.choices.contains { $0.seconds == TrashRetention.defaultSeconds })
    }

    /// Once a day would make the short choices untrue.
    @Test func aShortTimeIsCheckedOften() {
        #expect(TrashRetention.passInterval(retention: 60) == 60)
        #expect(TrashRetention.passInterval(retention: 3_600) == 900)
        #expect(TrashRetention.passInterval(retention: 86_400) == 21_600)
    }

    /// A pass costs several requests, so a long time never asks for more than one a day.
    @Test func aLongTimeIsCheckedOnceADay() {
        #expect(TrashRetention.passInterval(retention: 7 * 86_400) == 86_400)
        #expect(TrashRetention.passInterval(retention: 365 * 86_400) == 86_400)
        #expect(TrashRetention.passInterval(retention: nil) == 86_400)
    }
}
