// Apache 2 license - developer@infinitecontext.com

import CloudCore
import Foundation
import QuickLook
import RemoteEngine
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// A file someone asked to look at, and how.
struct ViewRequest: Identifiable {
    enum Origin {
        /// A copy on this phone, which works offline.
        case local(URL)
        case drive(RemoteEngine, RemoteItem, Connection)
    }

    enum Mode: Equatable {
        /// The start of the file as text, formatted when it's Markdown.
        case text(markdown: Bool)
        /// Pictures and Office documents, in Quick Look.
        case quickLook
        /// A web page, handed to another app through "Open in…".
        case handOff
    }

    let id = UUID()
    let name: String
    let origin: Origin
    let mode: Mode

    /// How a file of this kind opens from its magnifying glass.
    static func mode(for kind: ViewerKind) -> Mode {
        switch kind {
        case .text: .text(markdown: false)
        case .markdown: .text(markdown: true)
        case .html: .handOff
        case .image, .office: .quickLook
        }
    }
}

/// Shows a file without keeping it. Text reads only its start (`TextPreview.limit`), so it opens
/// at once from the server. Pictures and Office documents need the whole file: it's downloaded
/// into a temporary folder and removed on close, so a look is never a download. HTML goes to
/// another app, because CloudWanderer never draws a web page and iOS lets no app hand a file to
/// Safari.
struct FileViewerScreen: View {
    let request: ViewRequest
    let library: OfflineLibrary

    @Environment(\.dismiss) private var dismiss
    @State private var mode: ViewRequest.Mode
    @State private var phase = Phase.loading
    @State private var watch: DownloadWatch?
    /// The folder a whole file was downloaded into, removed on close.
    @State private var temporary: URL?
    @State private var attempt = 0

    init(request: ViewRequest, library: OfflineLibrary) {
        self.request = request
        self.library = library
        _mode = State(initialValue: request.mode)
    }

    private enum Phase {
        case loading
        case text(NSAttributedString, isCut: Bool)
        case quickLook(URL)
        case handOff(URL)
        case noHTMLApp
        case failed(String, canTryAgain: Bool)
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(Text(verbatim: FlattenedPackage.shownName(request.name)))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Close", systemImage: "xmark") { dismiss() }
                    }
                }
        }
        .task(id: attempt) { await load() }
        .onDisappear {
            if let temporary { try? FileManager.default.removeItem(at: temporary) }
        }
    }

    @ViewBuilder private var content: some View {
        switch phase {
        case .loading:
            VStack(spacing: 16) {
                ProgressView()
                if let watch {
                    DownloadLine(progress: watch.progress)
                        .padding(.horizontal, 32)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .text(let text, let isCut):
            VStack(spacing: 0) {
                if isCut {
                    Text("Showing the first 2 MB of this file.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                }
                ReadOnlyText(text: text)
            }
        case .quickLook(let file):
            QuickLookPreview(file: file)
                .ignoresSafeArea(edges: .bottom)
        case .handOff(let file):
            OpenInMenu(file: file, noApp: { phase = .noHTMLApp }, finished: { dismiss() })
        case .noHTMLApp:
            ContentUnavailableView {
                Label("No app on this iPhone opens HTML files.", systemImage: "safari")
            } actions: {
                Button("View Source") {
                    mode = .text(markdown: false)
                    attempt += 1
                }
                .buttonStyle(.borderedProminent)
                Button("Close") { dismiss() }
                    .buttonStyle(.bordered)
            }
        case .failed(let reason, let canTryAgain):
            ContentUnavailableView {
                Label("Couldn't show this file", systemImage: "eye.slash")
            } description: {
                Text(verbatim: reason)
            } actions: {
                if canTryAgain {
                    Button("Try Again") { attempt += 1 }
                        .buttonStyle(.borderedProminent)
                }
                Button("Close") { dismiss() }
                    .buttonStyle(.bordered)
            }
        }
    }

    private func load() async {
        phase = .loading
        do {
            switch mode {
            case .text(let markdown):
                let (data, isCut) = try await start()
                guard let text = TextPreview.decode(data, isCut: isCut) else {
                    phase = .failed(String(localized: "This file couldn't be read as text."), canTryAgain: false)
                    return
                }
                phase = .text(markdown ? TextLook.markdown(text) : TextLook.plain(text), isCut: isCut)
            case .quickLook:
                phase = .quickLook(try await wholeFile())
            case .handOff:
                phase = .handOff(try await wholeFile())
            }
        } catch is CancellationError {
            // Closed while loading.
        } catch {
            phase = .failed(await reason(for: error), canTryAgain: true)
        }
    }

    /// The first `TextPreview.limit` bytes, and whether the file goes on past them.
    private func start() async throws -> (Data, Bool) {
        let limit = TextPreview.limit
        switch request.origin {
        case .local(let file):
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: limit + 1) ?? Data()
            return (Data(data.prefix(limit)), data.count > limit)
        case .drive(let engine, let item, let connection):
            let size = item.size ?? Int64(limit + 1)
            guard size > 0 else { return (Data(), false) }
            let file = try library.temporaryFile(drive: connection.id)
            defer { try? FileManager.default.removeItem(at: file) }
            // Only this much ever comes from the server, however big the file.
            try await engine.read(item.path, offset: 0, length: min(size, Int64(limit + 1)), to: file)
            let data = try Data(contentsOf: file)
            return (Data(data.prefix(limit)), data.count > limit || size > Int64(limit))
        }
    }

    /// The whole file, on this phone. A download goes into its own folder under its real name,
    /// because Quick Look and other apps go by the name's extension.
    private func wholeFile() async throws -> URL {
        switch request.origin {
        case .local(let file):
            return file
        case .drive(let engine, let item, let connection):
            let incoming = try library.temporaryFile(drive: connection.id)
            let watch = DownloadWatch(total: item.size)
            self.watch = watch
            defer { self.watch = nil }
            do {
                _ = try await TransferContext.$progress.withValue({ watch.hear(bytes: $0) }) {
                    try await engine.verifiedDownload(item.path, to: incoming) { watch.hear($0) }
                }
                try Task.checkCancellation()
                let folder = incoming.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                temporary = folder
                let named = folder.appendingPathComponent(item.path.name)
                try FileManager.default.moveItem(at: incoming, to: named)
                return named
            } catch {
                try? FileManager.default.removeItem(at: incoming)
                throw error
            }
        }
    }

    private func reason(for error: Error) async -> String {
        switch request.origin {
        case .local:
            return error.localizedDescription
        case .drive(_, _, let connection):
            return await ConnectionChecks.explain(error, for: connection, device: .iPhone)
        }
    }
}

/// Text in a read-only view. UIKit's, because SwiftUI's `Text` is slow with a long document.
/// Nothing in it is a link: there are no data detectors, and no link attributes.
private struct ReadOnlyText: UIViewRepresentable {
    let text: NSAttributedString

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.dataDetectorTypes = []
        view.alwaysBounceVertical = true
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 32, right: 12)
        view.backgroundColor = .systemBackground
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if view.attributedText != text {
            view.attributedText = text
        }
    }
}

/// How plain text and Markdown look.
private enum TextLook {
    private static var code: UIFont {
        UIFont.monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize, weight: .regular)
    }

    static func plain(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: code, .foregroundColor: UIColor.label])
    }

    static func markdown(_ text: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (index, block) in MarkdownBlocks.parse(text).enumerated() {
            if index > 0 {
                result.append(NSAttributedString(string: "\n"))
            }
            let paragraph = NSMutableParagraphStyle()
            paragraph.paragraphSpacing = 8
            var base = UIFont.preferredFont(forTextStyle: .body)
            var color = UIColor.label
            var background: UIColor?
            var prefix = ""
            switch block.kind {
            case .heading(let level):
                let style: UIFont.TextStyle = switch level {
                case 1: .title1
                case 2: .title2
                case 3: .title3
                default: .headline
                }
                base = bold(UIFont.preferredFont(forTextStyle: style))
                paragraph.paragraphSpacingBefore = 6
            case .paragraph, .tableRow:
                break
            case .listItem(let marker, let depth):
                let indent = CGFloat(depth) * 20
                paragraph.firstLineHeadIndent = indent
                paragraph.headIndent = indent + 24
                paragraph.tabStops = [NSTextTab(textAlignment: .left, location: indent + 24)]
                prefix = marker + "\t"
            case .quote:
                paragraph.firstLineHeadIndent = 16
                paragraph.headIndent = 16
                color = .secondaryLabel
                base = italic(base)
            case .code:
                base = code
                background = .secondarySystemBackground
            }
            var attributes: [NSAttributedString.Key: Any] = [
                .font: base, .foregroundColor: color, .paragraphStyle: paragraph,
            ]
            if let background { attributes[.backgroundColor] = background }
            result.append(NSAttributedString(string: prefix, attributes: attributes))
            for run in block.content.runs {
                var piece = attributes
                let inline = run.inlinePresentationIntent ?? []
                var font = base
                if inline.contains(.code) { font = code }
                if inline.contains(.stronglyEmphasized) { font = bold(font) }
                if inline.contains(.emphasized) { font = italic(font) }
                piece[.font] = font
                if inline.contains(.strikethrough) {
                    piece[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                }
                // Looks like a link, and does nothing: nothing in a viewed file is followed.
                if run[WasLinkAttribute.self] == true {
                    piece[.underlineStyle] = NSUnderlineStyle.single.rawValue
                    piece[.foregroundColor] = UIColor.tintColor
                }
                result.append(NSAttributedString(string: String(block.content[run.range].characters), attributes: piece))
            }
        }
        return result
    }

    private static func bold(_ font: UIFont) -> UIFont {
        adding(.traitBold, to: font)
    }

    private static func italic(_ font: UIFont) -> UIFont {
        adding(.traitItalic, to: font)
    }

    private static func adding(_ trait: UIFontDescriptor.SymbolicTraits, to font: UIFont) -> UIFont {
        guard let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(trait))
        else { return font }
        return UIFont(descriptor: descriptor, size: 0)
    }
}

/// Apple's Quick Look, for pictures and Office documents. The app only reads, so markup and
/// editing are off.
private struct QuickLookPreview: UIViewControllerRepresentable {
    let file: URL

    func makeCoordinator() -> Coordinator { Coordinator(file: file) }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}

    final class Coordinator: NSObject, QLPreviewControllerDataSource, QLPreviewControllerDelegate {
        let file: URL

        init(file: URL) {
            self.file = file
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem {
            file as NSURL
        }

        func previewController(
            _ controller: QLPreviewController, editingModeFor previewItem: any QLPreviewItem
        ) -> QLPreviewItemEditingMode {
            .disabled
        }
    }
}

/// The iOS "Open in…" list, for HTML. The chosen app gets its own copy of the file and nothing
/// else: no password, no server address. `finished` comes once the list is closed and any copy
/// has been handed over, so the temporary download can go.
private struct OpenInMenu: UIViewControllerRepresentable {
    let file: URL
    let noApp: () -> Void
    let finished: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> AppearingController {
        let controller = AppearingController()
        let coordinator = context.coordinator
        controller.appeared = { [file] view in coordinator.present(file, from: view) }
        return controller
    }

    func updateUIViewController(_ controller: AppearingController, context: Context) {
        context.coordinator.noApp = noApp
        context.coordinator.finished = finished
    }

    /// The list can only be shown from a view that's on screen.
    final class AppearingController: UIViewController {
        var appeared: ((UIView) -> Void)?

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            appeared?(view)
            appeared = nil
        }
    }

    final class Coordinator: NSObject, UIDocumentInteractionControllerDelegate {
        var noApp: () -> Void = {}
        var finished: () -> Void = {}
        private var controller: UIDocumentInteractionController?
        private var isSending = false
        private var isDismissed = false

        func present(_ file: URL, from view: UIView) {
            let controller = UIDocumentInteractionController(url: file)
            controller.uti = UTType.html.identifier
            controller.delegate = self
            self.controller = controller
            if !controller.presentOpenInMenu(from: view.bounds, in: view, animated: true) {
                noApp()
            }
        }

        func documentInteractionController(
            _ controller: UIDocumentInteractionController, willBeginSendingToApplication application: String?
        ) {
            isSending = true
        }

        func documentInteractionController(
            _ controller: UIDocumentInteractionController, didEndSendingToApplication application: String?
        ) {
            isSending = false
            if isDismissed { finished() }
        }

        func documentInteractionControllerDidDismissOpenInMenu(_ controller: UIDocumentInteractionController) {
            isDismissed = true
            if !isSending { finished() }
        }
    }
}
