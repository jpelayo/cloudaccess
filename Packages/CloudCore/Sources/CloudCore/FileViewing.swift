// Apache 2 license - developer@infinitecontext.com

import Foundation
import UniformTypeIdentifiers

/// How the iPhone shows a file someone wants to look at.
public enum ViewerKind: Equatable, Sendable {
    /// Plain text, shown as it is.
    case text
    /// Markdown, formatted, with links that can't be followed and images that aren't loaded.
    case markdown
    /// A web page, handed to another app; its source can be shown as text.
    case html
    /// A picture, in Quick Look.
    case image
    /// A Word, Excel or PowerPoint document, in Quick Look.
    case office
}

/// Which files get the magnifying glass, by name, without reading them.
public enum FileViewer {
    static let office: Set<String> = ["docx", "xlsx", "pptx"]
    static let markdown: Set<String> = ["md", "markdown"]
    static let html: Set<String> = ["html", "htm"]
    /// For when the device's type database doesn't know the extension.
    static let plainText: Set<String> = ["txt", "text", "log"]

    public static func kind(of name: String) -> ViewerKind? {
        // Only macOS can turn a flattened package back into a document, and media has its player.
        guard !FlattenedPackage.isFlattened(name), !MediaFiles.isMedia(name),
              let ending = MediaFiles.fileExtension(of: name)
        else { return nil }
        // Markdown and HTML are text too, so they're picked out first.
        if markdown.contains(ending) { return .markdown }
        if html.contains(ending) { return .html }
        if office.contains(ending) { return .office }
        // An SVG is a picture written as XML, which Quick Look may not draw; its text always shows.
        if ending == "svg" { return .text }
        if let type = UTType(filenameExtension: ending), !type.isDynamic {
            if type.conforms(to: .image) { return .image }
            if type.conforms(to: .plainText) { return .text }
            return nil
        }
        return plainText.contains(ending) ? .text : nil
    }
}

/// The start of a text file, as a string.
public enum TextPreview {
    /// How much of a file is read to show it: enough for any document, and quick even for a log
    /// of many gigabytes, because only this much ever comes from the server.
    public static let limit = 2 * 1024 * 1024

    /// The bytes as text, or nil when they aren't text. UTF-8 first, then UTF-16 when the file
    /// says so with its byte-order mark, then Windows Latin-1, which reads any byte.
    /// - Parameter isCut: The bytes stop at `limit`, so the last character may be in pieces.
    public static func decode(_ data: Data, isCut: Bool) -> String? {
        let bytes = [UInt8](data)
        if bytes.isEmpty { return "" }
        if bytes.starts(with: [0xFF, 0xFE]) { return utf16(Array(bytes.dropFirst(2)), bigEndian: false, isCut: isCut) }
        if bytes.starts(with: [0xFE, 0xFF]) { return utf16(Array(bytes.dropFirst(2)), bigEndian: true, isCut: isCut) }
        let body = bytes.starts(with: [0xEF, 0xBB, 0xBF]) ? Array(bytes.dropFirst(3)) : bytes
        // Text has no zero bytes; a file with them is something else, whatever its name.
        if body.prefix(8192).contains(0) { return nil }
        let whole = isCut ? trimmingPartialUTF8(body) : body
        if let text = String(bytes: whole, encoding: .utf8) { return text }
        return String(bytes: body, encoding: .windowsCP1252) ?? String(bytes: body, encoding: .isoLatin1)
    }

    /// Drops a UTF-8 character the cut split, so the rest still reads as UTF-8.
    static func trimmingPartialUTF8(_ bytes: [UInt8]) -> [UInt8] {
        // A character is at most 4 bytes, so its lead is within the last 4.
        for back in 1...min(4, bytes.count) {
            let byte = bytes[bytes.count - back]
            if byte & 0b1100_0000 == 0b1000_0000 { continue }  // a continuation byte
            let length = byte < 0x80 ? 1 : byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : byte >= 0xC0 ? 2 : 1
            return length > back ? Array(bytes.dropLast(back)) : bytes
        }
        return bytes
    }

    private static func utf16(_ bytes: [UInt8], bigEndian: Bool, isCut: Bool) -> String? {
        var body = bytes
        if body.count % 2 == 1 { body.removeLast() }
        var units = stride(from: 0, to: body.count, by: 2).map { at -> UInt16 in
            let pair = (UInt16(body[at]), UInt16(body[at + 1]))
            return bigEndian ? pair.0 << 8 | pair.1 : pair.1 << 8 | pair.0
        }
        // A cut between the two halves of a character leaves the first half alone at the end.
        if isCut, let last = units.last, UTF16.isLeadSurrogate(last) { units.removeLast() }
        return String(utf16CodeUnits: units, count: units.count)
    }
}

/// One block of a Markdown document, ready to be drawn.
public struct MarkdownBlock: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case heading(level: Int)
        case paragraph
        /// `marker` is "•" or "3.", and `depth` 0 for a top-level item.
        case listItem(marker: String, depth: Int)
        case quote
        case code
        /// A table's row, its cells separated by " | ".
        case tableRow
    }

    public let kind: Kind
    /// The words, with bold, italic and code kept. Links and images are taken out.
    public let content: AttributedString
}

/// Words that were a link, kept without where it led.
public enum WasLinkAttribute: AttributedStringKey {
    public typealias Value = Bool
    public static let name = "CloudCore.wasLink"
}

/// Markdown read by Foundation's own parser, so no other code is needed to read it.
public enum MarkdownBlocks {
    public static func parse(_ text: String) -> [MarkdownBlock] {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: text, options: options) else {
            return [MarkdownBlock(kind: .paragraph, content: AttributedString(text))]
        }
        var blocks: [MarkdownBlock] = []
        var current: (key: AnyHashable, kind: MarkdownBlock.Kind, content: AttributedString, cell: Int?)?

        func finish() {
            guard let done = current else { return }
            var content = done.content
            if done.kind == .code {
                while content.characters.last == "\n" {
                    let last = content.characters.index(before: content.characters.endIndex)
                    content.removeSubrange(last..<content.endIndex)
                }
            }
            if !content.characters.isEmpty {
                blocks.append(MarkdownBlock(kind: done.kind, content: content))
            }
            current = nil
        }

        for run in parsed.runs {
            var piece = AttributedString(parsed[run.range])
            // Nothing in a viewed file is followed or fetched. A link's words stay, marked, so
            // they still look like one.
            if piece.link != nil {
                piece[WasLinkAttribute.self] = true
            }
            piece.link = nil
            piece.imageURL = nil
            let components = run.presentationIntent?.components ?? []
            let (key, kind, cell) = describe(components, intent: run.presentationIntent)
            if let open = current, open.key == key {
                if let cell, let previous = open.cell, cell != previous {
                    current?.content.append(AttributedString(" | "))
                }
                current?.content.append(piece)
                current?.cell = cell
            } else {
                finish()
                current = (key, kind, piece, cell)
            }
        }
        finish()
        return blocks
    }

    /// What block a run belongs to, and which kind. A table's cells are joined by row.
    private static func describe(
        _ components: [PresentationIntent.IntentType], intent: PresentationIntent?
    ) -> (AnyHashable, MarkdownBlock.Kind, Int?) {
        let kinds = components.map(\.kind)
        if let row = components.first(where: { isTableRow($0.kind) }) {
            let cell = kinds.lazy.compactMap(tableColumn).first
            return (AnyHashable(row.identity), .tableRow, cell)
        }
        let key = AnyHashable(intent)
        if kinds.contains(where: isCodeBlock) {
            return (key, .code, nil)
        }
        if let level = kinds.lazy.compactMap(headerLevel).first {
            return (key, .heading(level: level), nil)
        }
        if let item = kinds.firstIndex(where: { listOrdinal($0) != nil }), let ordinal = listOrdinal(kinds[item]) {
            // The list an item sits in is the one next to it, on the outer side. Which side that
            // is depends on the order the components come in, so it's read from where the
            // innermost block, the paragraph, sits.
            let innermostFirst = kinds.first.map(isBlock) ?? true
            let outer = innermostFirst
                ? kinds[(item + 1)...].first(where: isList)
                : kinds[..<item].last(where: isList)
            var marker = "•"
            if let outer, isOrderedList(outer) { marker = "\(ordinal)." }
            let depth = max(0, kinds.filter(isList).count - 1)
            return (key, .listItem(marker: marker, depth: depth), nil)
        }
        if kinds.contains(where: isBlockQuote) {
            return (key, .quote, nil)
        }
        return (key, .paragraph, nil)
    }

    private static func isBlock(_ kind: PresentationIntent.Kind) -> Bool {
        switch kind {
        case .paragraph, .header, .codeBlock: return true
        default: return false
        }
    }

    private static func isList(_ kind: PresentationIntent.Kind) -> Bool {
        switch kind {
        case .orderedList, .unorderedList: return true
        default: return false
        }
    }

    private static func isOrderedList(_ kind: PresentationIntent.Kind) -> Bool {
        if case .orderedList = kind { return true }
        return false
    }

    private static func isCodeBlock(_ kind: PresentationIntent.Kind) -> Bool {
        if case .codeBlock = kind { return true }
        return false
    }

    private static func isBlockQuote(_ kind: PresentationIntent.Kind) -> Bool {
        if case .blockQuote = kind { return true }
        return false
    }

    private static func isTableRow(_ kind: PresentationIntent.Kind) -> Bool {
        switch kind {
        case .tableRow, .tableHeaderRow: return true
        default: return false
        }
    }

    private static func tableColumn(_ kind: PresentationIntent.Kind) -> Int? {
        if case .tableCell(let column) = kind { return column }
        return nil
    }

    private static func headerLevel(_ kind: PresentationIntent.Kind) -> Int? {
        if case .header(let level) = kind { return level }
        return nil
    }

    private static func listOrdinal(_ kind: PresentationIntent.Kind) -> Int? {
        if case .listItem(let ordinal) = kind { return ordinal }
        return nil
    }
}
