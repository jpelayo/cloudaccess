// Apache 2 license - developer@infinitecontext.com

import AppKit
import CloudCore
import CloudDesign
import SwiftUI
import SyncCore

/// What's happening on a drive, file by file, so nobody has to guess what a sign means. Everything
/// here comes from what macOS and the extension report, and it updates while it's on screen.
struct DriveInformationView: View {
    @Environment(Drives.self) private var drives

    let connection: Connection
    /// Shows the drive's General page, where a password, an address or a server's identity is fixed.
    var openGeneral: () -> Void = {}

    @State private var report = DriveReport()
    @State private var isRetrying = false

    private static let refreshInterval = Duration.seconds(1)
    /// macOS's list changes slowly, and each read goes to another process.
    private static let readsBetweenLists = 3

    /// A file already listed above isn't repeated here.
    private var waitingFiles: [PendingFile] {
        let failed = Set(report.failures.map(\.id))
        let moving = Set(report.transfers.map { FlattenedPackage.shownName($0.name) })
        return report.pending.filter {
            !failed.contains($0.id) && !moving.contains(FlattenedPackage.shownName($0.name))
        }
    }

    private var canRetry: Bool {
        switch drives.status(of: connection) {
        case .notMoving, .needsAttention: true
        default: !report.failures.isEmpty
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.sectionGap) {
            summary
            transfers
            failed
            waiting
            finished
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: connection.id) {
            var reads = 0
            while !Task.isCancelled {
                if reads.isMultiple(of: Self.readsBetweenLists) {
                    await drives.refreshPending(of: connection)
                }
                reads += 1
                let latest = await drives.report(of: connection)
                if latest != report {
                    report = latest
                }
                try? await Task.sleep(for: Self.refreshInterval)
            }
        }
    }

    // MARK: Right now

    private var status: DriveStatus {
        let note = report.lastChecked.map { checked in
            let time = checked.formatted(date: .omitted, time: .standard)
            return String(localized: "Server last checked: \(time)")
        }
        let retry: DriveStatus.Button? = canRetry ? .tryAgain : nil
        switch drives.status(of: connection) {
        case .unmounted:
            return DriveStatus(
                symbol: "eject.fill", tone: .quiet, title: String(localized: "Ejected"),
                cause: String(localized: "This drive isn't in Finder, so nothing syncs."), button: .mount)
        case .needsEnabling:
            return DriveStatus(
                symbol: "power", tone: .needsYou, title: String(localized: "Turned off"),
                cause: String(localized: "Turn it on under System Settings, General, Login Items & Extensions."),
                button: .openExtensionSettings)
        case .offline:
            return drives.offlineStatus(of: connection)
        case .syncing(let count):
            return DriveStatus(
                symbol: "arrow.up.circle", tone: .busy, title: String(localized: "\(count) files to upload"),
                cause: speed, note: note, button: retry)
        case .needsAttention:
            return DriveStatus(
                symbol: "exclamationmark.triangle.fill", tone: .needsYou, title: String(localized: "Waiting for you"),
                cause: String(localized: "These files are on this Mac and haven't reached the server. CloudAccess won't send them until you press Try Again, or rename them."),
                button: .tryAgain)
        case .notMoving:
            return DriveStatus(
                symbol: "pause.circle.fill", tone: .needsYou, title: String(localized: "Uploads paused"),
                cause: stuckReason, button: .tryAgain)
        case .connected:
            if report.isBeingChecked {
                return DriveStatus(
                    symbol: "hourglass", tone: .quiet, title: String(localized: "macOS is checking this drive"),
                    cause: String(localized: "New files can wait until it finishes."), note: note, button: retry)
            }
            return DriveStatus(
                symbol: "checkmark.circle.fill", tone: .good, title: String(localized: "Up to date"),
                cause: String(localized: "Nothing is waiting to upload."), note: note, button: retry)
        }
    }

    private var stuckReason: String {
        if (drives.retrying[connection.id] ?? 0) > 0 {
            return String(localized: "These files keep failing. macOS tries them again by itself, and after 15 minutes of failures CloudAccess stops trying and waits for you.")
        }
        let count = drives.waiting[connection.id] ?? 0
        let quiet = Duration.seconds(Drives.stallLimit).formatted(.units(allowed: [.minutes], width: .wide))
        return String(localized: "\(count) files are waiting, and none has moved for \(quiet). This usually clears by itself. Try Again asks macOS to carry on.")
    }

    private var speed: String {
        let rate = report.transfers.compactMap(\.bytesPerSecond).reduce(0, +)
        let running = report.transfers.count
        guard running > 0 else { return String(localized: "Waiting for the next file to start.") }
        guard rate > 0 else { return String(localized: "\(running) moving now") }
        let perSecond = TransferRow.perSecond(rate)
        return String(localized: "\(running) moving now, at \(perSecond)")
    }

    private var summary: some View {
        DriveStatusCard(
            status: status, isChecking: drives.isChecking(connection), isRetrying: isRetrying,
            press: press, fix: fix, showLogs: { drives.showLogs() })
    }

    private func press(_ button: DriveStatus.Button) {
        switch button {
        case .checkAgain:
            Task { await drives.checkAgain([connection]) }
        case .tryAgain:
            isRetrying = true
            Task {
                await drives.retry(connection)
                isRetrying = false
            }
        case .mount:
            Task { await drives.toggleMount(connection) }
        case .openExtensionSettings:
            drives.openExtensionSettings()
        }
    }

    private func fix(_ action: DriveStatus.Fix.Action) {
        switch action {
        case .openGeneral: openGeneral()
        case .openTailscale: drives.openTailscale()
        case .openLocalNetworkSettings: drives.openLocalNetworkSettings()
        }
    }

    // MARK: The lists

    @ViewBuilder
    private var transfers: some View {
        if !report.transfers.isEmpty {
            VStack(alignment: .leading, spacing: Design.labelGap) {
                SectionLabel("Moving now")
                GrowingList(rows: report.transfers.count, rowHeight: 48) {
                    ForEach(report.transfers) { transfer in
                        TransferRow(transfer: transfer)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var failed: some View {
        if !report.failures.isEmpty {
            VStack(alignment: .leading, spacing: Design.labelGap) {
                SectionLabel("Attention: \(report.failures.count)")
                GrowingList(rows: report.failures.count, rowHeight: 76, maxHeight: 240) {
                    ForEach(report.failures) { failure in
                        FileRow(
                            title: FlattenedPackage.shownName(failure.name),
                            place: place(report.failedFolders[failure.id]),
                            problem: FileProblem(stored: failure.message).localized
                        ) {
                            Task { await drives.reveal(failure) }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var waiting: some View {
        let files = waitingFiles
        if !files.isEmpty {
            VStack(alignment: .leading, spacing: Design.labelGap) {
                SectionLabel("Waiting: \(files.count)")
                GrowingList(rows: files.count) {
                    ForEach(files) { file in
                        row(for: file)
                    }
                }
            }
        }
    }

    private func row(for file: PendingFile) -> FileRow {
        var problem: FileProblem?
        var note: String?
        switch file.state {
        case .waiting:
            if let size = file.size {
                let bytes = size.formatted(.byteCount(style: .file))
                note = String(localized: "Waiting its turn, \(bytes)")
            } else {
                note = String(localized: "Waiting its turn")
            }
        case .failing(let attempt):
            problem = FileProblem(stored: attempt.message).localized
            note = tries(attempt)
        case .refused(let reason):
            // macOS's own words, already in the language shown.
            problem = FileProblem(cause: reason, fix: String(localized: "Press Try Again."))
        case .held:
            note = String(localized: "Stopped until you press Try Again")
        }
        let title = FlattenedPackage.shownName(file.name)
        return FileRow(title: title, place: place(file.folder), problem: problem, note: note) {
            Task { await drives.reveal(file, in: connection) }
        }
    }

    /// What's been tried, for reading after the reason, which is what matters.
    private func tries(_ attempt: SyncAttempt) -> String {
        let last = attempt.lastFailed.formatted(date: .omitted, time: .shortened)
        return String(localized: "Tried \(attempt.count) times, last at \(last). macOS tries again by itself.")
    }

    private func place(_ folder: RemotePath?) -> String? {
        guard let folder else { return nil }
        guard !folder.components.isEmpty else { return String(localized: "At the top of the drive") }
        let path = folder.description
        return String(localized: "In \(path)")
    }

    @ViewBuilder
    private var finished: some View {
        if !report.recent.isEmpty {
            VStack(alignment: .leading, spacing: Design.labelGap) {
                HStack {
                    SectionLabel("Finished")
                    Spacer()
                    Text(totals)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                GrowingList(rows: report.recent.count, maxHeight: 180) {
                    ForEach(report.recent) { entry in
                        FileRow(title: FlattenedPackage.shownName(entry.name), note: description(of: entry))
                    }
                }
            }
        }
    }

    private func description(of entry: SyncActivity) -> String {
        let time = entry.date.formatted(date: .omitted, time: .standard)
        guard let size = entry.size.map({ $0.formatted(.byteCount(style: .file)) }) else {
            return switch entry.kind {
            case .uploaded: String(localized: "Uploaded at \(time)")
            case .downloaded: String(localized: "Downloaded at \(time)")
            case .deleted: String(localized: "Deleted at \(time)")
            }
        }
        return switch entry.kind {
        case .uploaded: String(localized: "Uploaded at \(time), \(size)")
        case .downloaded: String(localized: "Downloaded at \(time), \(size)")
        case .deleted: String(localized: "Deleted at \(time), \(size)")
        }
    }

    /// Each count has its own words, because in Spanish they agree with the number.
    private var totals: String {
        let counts = report.totals
        let figures = [
            String(localized: "\(counts.uploaded) uploaded"),
            String(localized: "\(counts.downloaded) downloaded"),
            String(localized: "\(counts.deleted) deleted"),
        ].formatted(.list(type: .and))
        guard let since = counts.since else { return figures }
        let day = since.formatted(date: .abbreviated, time: .omitted)
        return String(localized: "\(figures) since \(day)")
    }
}

/// A list with a scroll area of its own. Its height comes from how many rows it has, up to a
/// limit, never from measuring them, so a row that wraps scrolls rather than resizing the page.
private struct GrowingList<Content: View>: View {
    let rows: Int
    /// About how tall one row is, for working out the height.
    var rowHeight: CGFloat = 40
    var maxHeight: CGFloat = 200
    @ViewBuilder let content: Content

    private var height: CGFloat {
        min(maxHeight, CGFloat(max(rows, 1)) * rowHeight + 20)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                content
            }
            .padding(10)
        }
        .frame(height: height)
        .cardSurface()
    }
}

/// One file on the move, with how far it's got.
private struct TransferRow: View {
    let transfer: SyncTransfer

    /// An encrypted file is a little larger on the wire than on disk.
    private var share: Double {
        guard transfer.total > 0 else { return 0 }
        return min(Double(transfer.done) / Double(transfer.total), 1)
    }

    /// A speed, with the unit in the language shown.
    static func perSecond(_ rate: Double) -> String {
        let bytes = Int64(rate).formatted(.byteCount(style: .file))
        return String(localized: "\(bytes)/s")
    }

    private var figures: String {
        let done = transfer.done.formatted(.byteCount(style: .file))
        let total = transfer.total.formatted(.byteCount(style: .file))
        let isUpload = transfer.direction == .upload
        guard let rate = transfer.bytesPerSecond else {
            return isUpload
                ? String(localized: "Uploading, \(done) of \(total)")
                : String(localized: "Downloading, \(done) of \(total)")
        }
        let speed = Self.perSecond(rate)
        return isUpload
            ? String(localized: "Uploading, \(done) of \(total), at \(speed)")
            : String(localized: "Downloading, \(done) of \(total), at \(speed)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(FlattenedPackage.shownName(transfer.name))
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text(share, format: .percent.precision(.fractionLength(0)))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: share)
                .controlSize(.small)
            Text(figures)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

/// A file, where it is, why it didn't go and what to do. All of it wraps and can be selected,
/// because someone may have to read this closely, or pass it on.
private struct FileRow: View {
    let title: String
    var place: String?
    var problem: FileProblem?
    var note: String?
    var reveal: (() -> Void)?

    /// What Copy Details puts on the clipboard, in the language shown, for a person to pass on.
    private var fullText: String {
        var lines = [title]
        if let place {
            lines.append(place)
        }
        if let problem {
            lines.append(String(localized: "Why: \(problem.cause)"))
            if !problem.fix.isEmpty {
                lines.append(String(localized: "What to do: \(problem.fix)"))
            }
        }
        if let note {
            lines.append(note)
        }
        return lines.joined(separator: "\n")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                if let place {
                    Text(place)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                if let problem {
                    // A value put into the sentence is shown as it is, never read as Markdown.
                    Text("**Why:** \(problem.cause)")
                        .font(.system(size: 12))
                    if !problem.fix.isEmpty {
                        Text("**What to do:** \(problem.fix)")
                            .font(.system(size: 12))
                    }
                }
                if let note {
                    Text(note)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            if let reveal {
                Button("Reveal in Finder", systemImage: "magnifyingglass", action: reveal)
                    .buttonStyle(.icon)
                    .help("Reveal in Finder")
            }
        }
        .contextMenu {
            if let reveal {
                Button("Reveal in Finder", action: reveal)
            }
            Button("Copy Details") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(fullText, forType: .string)
            }
        }
    }
}

