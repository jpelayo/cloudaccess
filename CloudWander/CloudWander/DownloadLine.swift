// Apache 2 license - developer@infinitecontext.com

import CloudCore
import Observation
import SwiftUI

/// Hears a download from wherever the engine reports it, and keeps what the row shows.
@Observable
final class DownloadWatch {
    private(set) var progress: DownloadProgress

    init(total: Int64?) {
        progress = DownloadProgress(total: total)
    }

    nonisolated func hear(_ stage: DownloadStage) {
        let now = Date()
        Task { @MainActor in self.progress.enter(stage, now: now) }
    }

    nonisolated func hear(bytes: Int64) {
        Task { @MainActor in self.progress.received(bytes) }
    }
}

/// The step, the percent and the speed, over a thin bar. It refreshes every second on its own, so
/// a download that has stalled shows its speed falling.
struct DownloadLine: View {
    let progress: DownloadProgress

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 4) {
                Text(progress.caption(now: context.date))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let fraction = progress.fraction {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .tint(progress.step == .processing ? .green : .accentColor)
                        .animation(.linear(duration: 0.4), value: fraction)
                }
            }
        }
    }
}
