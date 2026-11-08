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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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

    private var headline: (symbol: String, title: String, detail: String, tint: Color?) {
        switch drives.status(of: connection) {
        case .unmounted:
            return ("eject.fill", "Ejected", "This drive isn't in Finder, so nothing syncs.", nil)
        case .needsEnabling:
            return (
                "exclamationmark.triangle.fill", "Turned off",
                "Turn it on under System Settings, General, Login Items & Extensions.", .red)
        case .offline:
            return ("exclamationmark.triangle.fill", "Not connected", drives.offlineMessage(of: connection), .red)
        case .syncing(let count):
            return ("arrow.up.circle", count == 1 ? "1 file to upload" : "\(count) files to upload", speed, .blue)
        case .needsAttention:
            return (
                "exclamationmark.triangle.fill", "Waiting for you",
                "These files are on this Mac and haven't reached the server. CloudMount won't send them until you press Try Again, or rename them.",
                .orange)
        case .notMoving:
            return ("pause.circle.fill", "Uploads paused", stuckReason, .orange)
        case .connected:
            if report.isBeingChecked {
                return ("hourglass", "macOS is checking this drive", "New files can wait until it finishes.", nil)
            }
            return ("checkmark.circle.fill", "Up to date", "Nothing is waiting to upload.", .green)
        }
    }

    private var stuckReason: String {
        if (drives.retrying[connection.id] ?? 0) > 0 {
            return "These files keep failing. macOS tries them again by itself, and after 15 minutes of failures CloudMount stops trying and waits for you."
        }
        let count = drives.waiting[connection.id] ?? 0
        let files = count == 1 ? "1 file is waiting" : "\(count) files are waiting"
        let minutes = Int(Drives.stallLimit / 60)
        return "\(files), and none has moved for \(minutes) minutes. This usually clears by itself. Try Again asks macOS to carry on."
    }

    private var speed: String {
        let rate = report.transfers.compactMap(\.bytesPerSecond).reduce(0, +)
        let running = report.transfers.count
        guard running > 0 else { return "Waiting for the next file to start." }
        let files = running == 1 ? "1 moving now" : "\(running) moving now"
        guard rate > 0 else { return files }
        return "\(files), at \(Int64(rate).formatted(.byteCount(style: .file)))/s"
    }

    private var summary: some View {
        let shown = headline
        return Card {
            IconRow(shown.symbol, shown.title, subtitle: shown.detail, tint: shown.tint) {
                if canRetry {
                    Button("Try Again") {
                        isRetrying = true
                        Task {
                            await drives.retry(connection)
                            isRetrying = false
                        }
                    }
                    .buttonStyle(.pill)
                    .disabled(isRetrying)
                }
            }
            if let lastChecked = report.lastChecked {
                KeyValueRow("Server last checked", lastChecked.formatted(date: .omitted, time: .standard))
            }
            IconRow("doc.text", "Logs", subtitle: "A record of what happened on your drives.") {
                Button("Show Logs") { drives.showLogs() }
                    .buttonStyle(.pill)
            }
        }
    }

    // MARK: The lists

    @ViewBuilder
    private var transfers: some View {
        if !report.transfers.isEmpty {
            VStack(alignment: .leading, spacing: Design.labelGap) {
                SectionLabel("Moving now")
                GrowingList {
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
                GrowingList {
                    ForEach(report.failures) { failure in
                        FileRow(
                            title: FlattenedPackage.shownName(failure.name),
                            place: place(report.failedFolders[failure.id]),
                            problem: FileProblem(stored: failure.message)
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
                GrowingList {
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
            note = "Waiting its turn" + (file.size.map { ", \($0.formatted(.byteCount(style: .file)))" } ?? "")
        case .failing(let attempt):
            problem = FileProblem(stored: attempt.message)
            note = tries(attempt)
        case .refused(let reason):
            problem = FileProblem(cause: reason, fix: "Press Try Again.")
        case .held:
            note = "Stopped until you press Try Again"
        }
        let title = FlattenedPackage.shownName(file.name)
        return FileRow(title: title, place: place(file.folder), problem: problem, note: note) {
            Task { await drives.reveal(file, in: connection) }
        }
    }

    /// What's been tried, for reading after the reason, which is what matters.
    private func tries(_ attempt: SyncAttempt) -> String {
        let count = attempt.count == 1 ? "Tried once" : "Tried \(attempt.count) times"
        let last = attempt.lastFailed.formatted(date: .omitted, time: .shortened)
        return "\(count), last at \(last). macOS tries again by itself."
    }

    private func place(_ folder: RemotePath?) -> String? {
        guard let folder else { return nil }
        return folder.components.isEmpty ? "At the top of the drive" : "In \(folder)"
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
                GrowingList(maxHeight: 180) {
                    ForEach(report.recent) { entry in
                        FileRow(title: FlattenedPackage.shownName(entry.name), note: description(of: entry))
                    }
                }
            }
        }
    }

    private func description(of entry: SyncActivity) -> String {
        let verb = switch entry.kind {
        case .uploaded: "Uploaded"
        case .downloaded: "Downloaded"
        case .deleted: "Deleted"
        }
        let size = entry.size.map { ", \($0.formatted(.byteCount(style: .file)))" } ?? ""
        return "\(verb) at \(entry.date.formatted(date: .omitted, time: .standard))\(size)"
    }

    private var totals: String {
        let counts = report.totals
        var text = "\(counts.uploaded) uploaded, \(counts.downloaded) downloaded, \(counts.deleted) deleted"
        if let since = counts.since {
            text += " since \(since.formatted(date: .abbreviated, time: .omitted))"
        }
        return text
    }
}

/// SwiftUI gives a sheet the size of its content, with no edge to drag, so this adds one.
struct ResizableSheet: NSViewRepresentable {
    let isResizable: Bool

    final class Marker: NSView {
        var isResizable = false {
            didSet { apply() }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        private func apply() {
            if isResizable {
                window?.styleMask.insert(.resizable)
            } else {
                window?.styleMask.remove(.resizable)
            }
        }
    }

    func makeNSView(context: Context) -> Marker {
        Marker()
    }

    func updateNSView(_ view: Marker, context: Context) {
        view.isResizable = isResizable
    }
}

/// A list that shares whatever height the window has. Rows are as tall as their text needs, so
/// nothing is cut off, and only this area scrolls.
private struct GrowingList<Content: View>: View {
    var maxHeight: CGFloat = .infinity
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                content
            }
            .padding(10)
        }
        .frame(minHeight: 84, maxHeight: maxHeight)
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

    private var figures: String {
        let done = transfer.done.formatted(.byteCount(style: .file))
        let total = transfer.total.formatted(.byteCount(style: .file))
        let verb = transfer.direction == .upload ? "Uploading" : "Downloading"
        guard let rate = transfer.bytesPerSecond else { return "\(verb), \(done) of \(total)" }
        return "\(verb), \(done) of \(total), at \(Int64(rate).formatted(.byteCount(style: .file)))/s"
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

    private var fullText: String {
        var lines = [title]
        lines += [place, problem.map { "Why: \($0.cause)" }].compactMap { $0 }
        if let fix = problem?.fix, !fix.isEmpty {
            lines.append("What to do: \(fix)")
        }
        return (lines + [note].compactMap { $0 }).joined(separator: "\n")
    }

    private func labelled(_ label: String, _ text: String) -> Text {
        Text("\(label): ").fontWeight(.semibold) + Text(text)
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
                    labelled("Why", problem.cause)
                        .font(.system(size: 12))
                    if !problem.fix.isEmpty {
                        labelled("What to do", problem.fix)
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
