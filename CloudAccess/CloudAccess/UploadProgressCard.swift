// Apache 2 license - developer@infinitecontext.com

import CloudCore
import CloudDesign
import SwiftUI
import SyncCore

/// The panel's view of uploads under way: how much of the batch has gone, how fast, and the files
/// moving now, each with its own bar. It reads the moving files every second, but only while the
/// panel is open, because the panel's view goes when the panel closes.
struct UploadProgressCard: View {
    @Environment(Drives.self) private var drives

    let line: ActivityLine
    let open: () -> Void

    @State private var moving: [(connection: Connection, transfer: SyncTransfer)] = []

    /// Rows kept for files, so the panel doesn't change height each time a file finishes.
    private static let slots = 3
    private static let refreshInterval = Duration.seconds(1)

    private var rate: Double {
        moving.compactMap(\.transfer.bytesPerSecond).reduce(0, +)
    }

    private var left: Int64 {
        max(0, line.total - line.sent)
    }

    private var title: String {
        line.uploading.count > 1
            ? String(localized: "\(line.count) files to upload on \(line.uploading.count) drives")
            : String(localized: "\(line.count) files to upload")
    }

    private var subtitle: String {
        guard !moving.isEmpty else { return String(localized: "Waiting for the next file to start.") }
        let speed = Self.perSecond(rate)
        guard left > 0 else {
            return String(localized: "\(moving.count) moving now, at \(speed)")
        }
        let bytes = left.formatted(.byteCount(style: .file))
        return rate > 0 ? String(localized: "\(bytes) left, at \(speed)") : String(localized: "\(bytes) left")
    }

    /// How much of the batch has gone, or nil when macOS doesn't say.
    private var share: Double? {
        guard line.total > 0 else { return nil }
        return min(1, Double(line.sent) / Double(line.total))
    }

    private struct Row: Identifiable {
        let id: String
        let name: String
        let share: Double?
        let detail: String
    }

    /// The files moving now, then the next ones waiting, up to the slots kept for them.
    private var rows: [Row] {
        let shownDrive = line.uploading.count > 1
        let slots = min(Self.slots, line.count)
        var rows = moving.prefix(slots).map { entry in
            let transfer = entry.transfer
            let share = transfer.total > 0 ? min(1, Double(transfer.done) / Double(transfer.total)) : 0
            let detail = Self.figures(transfer)
            return Row(
                id: "\(entry.connection.id)/\(transfer.id)", name: FlattenedPackage.shownName(transfer.name),
                share: share, detail: shownDrive ? "\(entry.connection.displayName) · \(detail)" : detail)
        }
        // A file macOS still lists as waiting may be the one already moving.
        let movingNames = Set(moving.map { FlattenedPackage.shownName($0.transfer.name) })
        let next = line.uploading.flatMap { connection in
            (drives.pending[connection.id] ?? [])
                .filter { $0.state == .waiting && !movingNames.contains(FlattenedPackage.shownName($0.name)) }
                .map { (connection: connection, file: $0) }
        }
        for entry in next.prefix(slots - rows.count) {
            let file = entry.file
            let detail = file.size.map { String(localized: "Waiting its turn, \($0.formatted(.byteCount(style: .file)))") }
                ?? String(localized: "Waiting its turn")
            rows.append(Row(
                id: "\(entry.connection.id)/\(file.id)", name: FlattenedPackage.shownName(file.name), share: nil,
                detail: shownDrive ? "\(entry.connection.displayName) · \(detail)" : detail))
        }
        return rows
    }

    var body: some View {
        let shown = rows
        Button(action: open) {
            VStack(alignment: .leading, spacing: 10) {
                IconRow("arrow.up.circle", title, subtitle: subtitle, tint: .blue) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                if line.isLowOnSpace {
                    // Saves can't be held back, because macOS owns them, so this can only say so.
                    Text("Your Mac is low on space. Files stay on it until they're uploaded.")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let share {
                    batch(share)
                }
                if !shown.isEmpty {
                    Divider()
                    ForEach(shown) { row in
                        fileRow(row)
                    }
                    let more = line.count - shown.count
                    if more > 0 {
                        Text("And \(more) more waiting")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(Design.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show which files, and why")
        .accessibilityHint("Shows which files, and why")
        .task(id: line.uploading.map(\.id)) {
            while !Task.isCancelled {
                moving = await drives.uploadsMoving(on: line.uploading)
                try? await Task.sleep(for: Self.refreshInterval)
            }
        }
    }

    private func batch(_ share: Double) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ProgressView(value: share)
                .controlSize(.small)
            HStack {
                let sent = line.sent.formatted(.byteCount(style: .file))
                let total = line.total.formatted(.byteCount(style: .file))
                Text("\(sent) of \(total)")
                Spacer(minLength: 8)
                Text(share, format: .percent.precision(.fractionLength(0)))
            }
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private func fileRow(_ row: Row) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(verbatim: row.name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                if let share = row.share {
                    Text(share, format: .percent.precision(.fractionLength(0)))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            ProgressView(value: row.share ?? 0)
                .controlSize(.mini)
            Text(verbatim: row.detail)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    /// A speed, with the unit in the language shown.
    static func perSecond(_ rate: Double) -> String {
        let bytes = Int64(rate).formatted(.byteCount(style: .file))
        return String(localized: "\(bytes)/s")
    }

    private static func figures(_ transfer: SyncTransfer) -> String {
        let done = transfer.done.formatted(.byteCount(style: .file))
        let total = transfer.total.formatted(.byteCount(style: .file))
        guard let rate = transfer.bytesPerSecond else {
            return String(localized: "Uploading, \(done) of \(total)")
        }
        let speed = perSecond(rate)
        return String(localized: "Uploading, \(done) of \(total), at \(speed)")
    }
}
