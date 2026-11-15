// Apache 2 license - developer@infinitecontext.com

@testable import CloudCore
import Foundation
import Testing

@Suite struct FileViewerTests {
    @Test func eachKindIsKnownByName() {
        let cases: [(String, ViewerKind)] = [
            ("notes.txt", .text), ("NOTES.TXT", .text), ("server.log", .text), ("main.swift", .text),
            ("README.md", .markdown), ("Guide.Markdown", .markdown),
            ("page.html", .html), ("old.HTM", .html),
            ("photo.jpg", .image), ("photo.HEIC", .image), ("shot.png", .image),
            ("report.docx", .office), ("sums.xlsx", .office), ("talk.PPTX", .office),
        ]
        for (name, kind) in cases {
            #expect(FileViewer.kind(of: name) == kind, "\(name)")
        }
    }

    @Test func markdownIsNotPlainText() {
        #expect(FileViewer.kind(of: "a.md") == .markdown)
    }

    /// Quick Look may not draw an SVG, and it's text underneath.
    @Test func anSVGShowsAsText() {
        #expect(FileViewer.kind(of: "logo.svg") == .text)
    }

    @Test func otherFilesGetNoViewer() {
        for name in ["film.mkv", "song.mp3", "archive.zip", "manual.pdf", "Budget.numbers.pkgf", "README"] {
            #expect(FileViewer.kind(of: name) == nil, "\(name)")
        }
    }
}

@Suite struct TextPreviewTests {
    @Test func utf8ReadsAsItIs() {
        #expect(TextPreview.decode(Data("Año: 2026 ✓".utf8), isCut: false) == "Año: 2026 ✓")
    }

    @Test func aCutInsideACharacterIsTrimmed() {
        for text in ["añ", "a✓", "a😀"] {
            let cut = Data(text.utf8.dropLast())
            #expect(TextPreview.decode(cut, isCut: true) == "a", "\(text)")
        }
    }

    @Test func aWholeLastCharacterStays() {
        #expect(TextPreview.decode(Data("a✓".utf8), isCut: true) == "a✓")
    }

    @Test func utf16IsReadByItsByteOrderMark() {
        #expect(TextPreview.decode(Data([0xFF, 0xFE, 0x41, 0x00, 0xF1, 0x00]), isCut: false) == "Añ")
        #expect(TextPreview.decode(Data([0xFE, 0xFF, 0x00, 0x41, 0x00, 0xF1]), isCut: false) == "Añ")
        // Cut between the halves of 😀, and in the middle of a unit.
        #expect(TextPreview.decode(Data([0xFF, 0xFE, 0x41, 0x00, 0x3D, 0xD8]), isCut: true) == "A")
        #expect(TextPreview.decode(Data([0xFF, 0xFE, 0x41, 0x00, 0x42]), isCut: true) == "A")
    }

    @Test func aUTF8ByteOrderMarkIsDropped() {
        #expect(TextPreview.decode(Data([0xEF, 0xBB, 0xBF] + Array("hi".utf8)), isCut: false) == "hi")
    }

    @Test func bytesThatArentUTF8ReadAsLatin1() {
        #expect(TextPreview.decode(Data([0xE9, 0x74, 0xE9]), isCut: false) == "été")
    }

    @Test func aFileWithZeroBytesIsntText() {
        #expect(TextPreview.decode(Data([0x50, 0x4B, 0x03, 0x04, 0x00, 0x00]), isCut: false) == nil)
    }

    @Test func anEmptyFileIsEmptyText() {
        #expect(TextPreview.decode(Data(), isCut: false) == "")
    }
}

@Suite struct MarkdownBlocksTests {
    private func blocks(_ text: String) -> [(MarkdownBlock.Kind, String)] {
        MarkdownBlocks.parse(text).map { ($0.kind, String($0.content.characters)) }
    }

    @Test func headingsKeepTheirLevel() {
        let parsed = blocks("# One\n\n### Three")
        #expect(parsed.map(\.0) == [.heading(level: 1), .heading(level: 3)])
        #expect(parsed.map(\.1) == ["One", "Three"])
    }

    @Test func listsKeepTheirMarkersAndDepth() {
        let parsed = blocks("- one\n- two\n  - nested\n\n1. first\n2. second")
        #expect(parsed.map(\.0) == [
            .listItem(marker: "•", depth: 0), .listItem(marker: "•", depth: 0), .listItem(marker: "•", depth: 1),
            .listItem(marker: "1.", depth: 0), .listItem(marker: "2.", depth: 0),
        ])
        #expect(parsed.map(\.1) == ["one", "two", "nested", "first", "second"])
    }

    @Test func quotesAndCodeAreTheirOwnBlocks() {
        let parsed = blocks("> quoted\n\n```\nlet x = 1\n```")
        #expect(parsed.map(\.0) == [.quote, .code])
        #expect(parsed.map(\.1) == ["quoted", "let x = 1"])
    }

    @Test func aTableReadsRowByRow() {
        let parsed = blocks("| A | B |\n|---|---|\n| 1 | 2 |")
        #expect(parsed.map(\.0) == [.tableRow, .tableRow])
        #expect(parsed.map(\.1) == ["A | B", "1 | 2"])
    }

    @Test func boldAndItalicAreKept() throws {
        let block = try #require(MarkdownBlocks.parse("Some **bold** and *italic*.").first)
        let intents = block.content.runs.compactMap(\.inlinePresentationIntent)
        #expect(intents.contains { $0.contains(.stronglyEmphasized) })
        #expect(intents.contains { $0.contains(.emphasized) })
    }

    /// Nothing in a viewed file is followed or fetched.
    @Test func linksAndImagesKeepOnlyTheirWords() throws {
        let block = try #require(
            MarkdownBlocks.parse("A [link](https://example.com) and ![a cat](https://example.com/cat.png).").first)
        #expect(String(block.content.characters) == "A link and a cat.")
        #expect(block.content.runs.allSatisfy { $0.link == nil && $0.imageURL == nil })
        // The link's words are marked, so they can still look like one.
        let marked = block.content.runs.filter { $0[WasLinkAttribute.self] == true }
        #expect(marked.map { String(block.content[$0.range].characters) } == ["link"])
    }
}
