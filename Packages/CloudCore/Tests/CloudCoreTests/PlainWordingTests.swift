// Apache 2 license - developer@infinitecontext.com

@testable import CloudCore
import Foundation
import Testing

/// Some sentences are kept exactly as the engine or the records word them, for support, and shown
/// in plain words. The English table holds those plain words.
@Suite struct PlainWordingTests {
    private static let resources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Sources/CloudCore/Resources")

    private static func table(_ language: String) throws -> [String: String] {
        let file = resources.appending(path: "\(language).lproj/Localizable.strings")
        return try #require(
            try PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil) as? [String: String])
    }

    @Test func everyPlainEnglishSentenceHasSpanish() throws {
        let english = try Self.table("en")
        let spanish = try Self.table("es")
        #expect(!english.isEmpty)
        for key in english.keys {
            #expect(spanish[key] != nil, "\(key) has plain English but no Spanish")
        }
    }

    /// Plain English never takes values, because `Words.english` reads that table for a sentence
    /// with values, and what's kept would change with it.
    @Test func plainEnglishTakesNoValues() throws {
        for (key, plain) in try Self.table("en") {
            #expect(TranslationTests.placeholders(key).isEmpty, "\(key)")
            #expect(TranslationTests.placeholders(plain).isEmpty, "\(plain)")
        }
    }

    @Test func anInternalReasonIsShownPlainlyAndKeptExactly() {
        let error = RemoteError.failed(.root, "this device's claim expired during the save")
        #expect(error.englishDescription == "this device's claim expired during the save")
        #expect(error.errorDescription == "the save took too long, so it was stopped to keep other devices' saves safe")
    }

    @Test func aLostAnswerIsNotAlarming() {
        let reason = "the server's answer was lost, so this change may or may not have happened"
        #expect(Words.shown(reason) == "the connection dropped before the server confirmed this change")
    }
}
