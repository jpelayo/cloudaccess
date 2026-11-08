// Apache 2 license - developer@infinitecontext.com

import CloudCore
import Foundation
import Testing

/// What the iPhone shows while a file comes down, and what the log keeps of how long each step took.
@Suite struct DownloadProgressTests {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func at(_ seconds: TimeInterval) -> Date {
        start.addingTimeInterval(seconds)
    }

    @Test func itStartsByPreparing() {
        let progress = DownloadProgress(total: 8_000_000, now: start)
        #expect(progress.step == .preparing)
        #expect(progress.caption(now: start) == "Preparing…")
        #expect(progress.fraction == 0)
    }

    @Test func downloadingShowsThePercentAndTheSpeed() {
        var progress = DownloadProgress(total: 8_000_000, now: start)
        progress.enter(.downloading, now: at(1))
        progress.received(3_440_000)

        #expect(progress.step == .downloading)
        #expect(progress.fraction == 0.43)
        let caption = progress.caption(now: at(5))
        #expect(caption.hasPrefix("Downloading 43% · "))
        #expect(caption.hasSuffix("/s"))
    }

    @Test func aSpeedNeedsAMomentToMeanAnything() {
        var progress = DownloadProgress(total: 8_000_000, now: start)
        progress.enter(.downloading, now: at(1))
        progress.received(100_000)
        #expect(!progress.caption(now: at(1.5)).hasSuffix("/s"))
    }

    @Test func checkingAfterwardsIsProcessing() {
        var progress = DownloadProgress(total: 8_000_000, now: start)
        progress.enter(.downloading, now: at(1))
        progress.received(8_000_000)
        progress.enter(.verifying, now: at(9))

        #expect(progress.step == .processing)
        #expect(progress.caption(now: at(9)) == "Processing…")
        #expect(progress.fraction == 1)
    }

    /// An encrypted file's count can pass the listed size by a little, and a bar past its end
    /// would look broken.
    @Test func theBarNeverPassesItsEnd() {
        var progress = DownloadProgress(total: 1_000, now: start)
        progress.enter(.downloading, now: start)
        progress.received(1_200)
        #expect(progress.fraction == 1)
    }

    @Test func anUnknownSizeShowsWhatArrived() {
        var progress = DownloadProgress(total: nil, now: start)
        progress.enter(.downloading, now: start)
        progress.received(2_000_000)
        #expect(progress.fraction == nil)
        #expect(progress.caption(now: at(4)).hasPrefix("Downloading "))
        #expect(!progress.caption(now: at(4)).contains("%"))
    }

    /// A slow download has to say where the time went.
    @Test func theLogSaysHowLongEachStepTook() {
        var progress = DownloadProgress(total: 8_000_000, now: start)
        progress.enter(.downloading, now: at(2))
        progress.received(8_000_000)
        progress.enter(.verifying, now: at(42))

        let timings = progress.timings(now: at(43))
        #expect(timings.contains("preparing 2 s"))
        #expect(timings.contains("downloading 40 s at "))
        #expect(timings.contains("processing 1 s"))
    }

    /// A retry starts the count again, and the time spent adds up.
    @Test func aRetryStartsTheBarAgain() {
        var progress = DownloadProgress(total: 8_000_000, now: start)
        progress.enter(.downloading, now: at(1))
        progress.received(8_000_000)
        progress.enter(.verifying, now: at(5))
        progress.enter(.checking, now: at(6))
        progress.enter(.downloading, now: at(7))

        #expect(progress.fraction == 0)
        #expect(progress.timings(now: at(8)).contains("preparing 2 s"))
    }
}
