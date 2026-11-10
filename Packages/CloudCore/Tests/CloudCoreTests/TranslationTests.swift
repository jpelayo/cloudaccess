// Apache 2 license - developer@infinitecontext.com

@testable import CloudCore
import Foundation
import Testing

/// Every sentence a person can see has Spanish, and the Spanish keeps every value the English has,
/// in the same kinds. A missing `%@` would drop a drive's name, and a wrong one can crash.
@Suite struct TranslationTests {
    private static let package = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let repository = package.deletingLastPathComponent().deletingLastPathComponent()

    /// The app catalogs Xcode keeps up to date from the code.
    static let catalogs = [
        "CloudAccess/CloudAccess/Localizable.xcstrings",
        "CloudAccess/CloudAccess/InfoPlist.xcstrings",
        "CloudAccess/CloudAccessFileProvider/Localizable.xcstrings",
        "CloudWanderer/CloudWanderer/Localizable.xcstrings",
        "CloudWanderer/CloudWanderer/InfoPlist.xcstrings",
    ]

    /// The values in a format, in order, as kinds: `%@`, `%lld` and so on.
    static func placeholders(_ text: String) -> [String] {
        let pattern = /%(?:\d+\$)?(@|lld|llu|ld|lu|d|u|lf|f|%)/
        return text.matches(of: pattern).map { String($0.output.1) }.filter { $0 != "%" }.sorted()
    }

    @Test func thePackagesSpanishIsCompleteAndKeepsItsValues() throws {
        let file = Self.package.appending(path: "Sources/CloudCore/Resources/es.lproj/Localizable.strings")
        let table = try #require(
            try PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil) as? [String: String])
        #expect(!table.isEmpty)
        for (english, spanish) in table {
            #expect(!spanish.isEmpty, "\(english) has no Spanish")
            #expect(Self.placeholders(spanish) == Self.placeholders(english), "\(english) → \(spanish)")
        }
    }

    @Test func thePackagesPluralsHaveBothLanguages() throws {
        func keys(_ language: String) throws -> Set<String> {
            let file = Self.package.appending(path: "Sources/CloudCore/Resources/\(language).lproj/Localizable.stringsdict")
            guard FileManager.default.fileExists(atPath: file.path) else { return [] }
            let table = try #require(
                try PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil) as? [String: Any])
            return Set(table.keys)
        }
        #expect(try keys("en") == keys("es"))
    }

    @Test(arguments: catalogs) func everyAppStringHasSpanish(_ path: String) throws {
        let file = Self.repository.appending(path: path)
        let catalog = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let strings = try #require(catalog["strings"] as? [String: [String: Any]])
        #expect(!strings.isEmpty)
        for (key, entry) in strings {
            if entry["shouldTranslate"] as? Bool == false { continue }
            let localizations = entry["localizations"] as? [String: Any]
            let english = ((localizations?["en"] as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String ?? key
            guard let spanish = localizations?["es"] as? [String: Any] else {
                Issue.record("\(path): \(key) has no Spanish")
                continue
            }
            let substitutions = spanish["substitutions"] as? [String: [String: Any]] ?? [:]
            for unit in Self.units(in: spanish) {
                #expect(unit["state"] as? String == "translated", "\(path): \(key) isn't translated")
                let value = unit["value"] as? String ?? ""
                #expect(!value.isEmpty, "\(path): \(key) is empty")
                // A plural form may leave its number out, such as "un archivo", so only a single
                // form has to keep every value.
                if Self.units(in: spanish).count == 1 {
                    #expect(Self.placeholders(value) == Self.placeholders(english), "\(path): \(key) → \(value)")
                }
                // A sentence with a plural inside names it, and the Spanish has to carry it.
                for name in value.matches(of: /%(?:\d+\$)?#@(\w+)@/).map({ String($0.output.1) }) {
                    #expect(substitutions[name] != nil, "\(path): \(key) has no Spanish \(name)")
                }
            }
            for (name, substitution) in substitutions {
                let forms = Self.units(in: substitution)
                #expect(!forms.isEmpty, "\(path): \(key) has no Spanish forms for \(name)")
                for form in forms {
                    #expect(form["state"] as? String == "translated", "\(path): \(key) \(name) isn't translated")
                    #expect(!(form["value"] as? String ?? "").isEmpty, "\(path): \(key) \(name) is empty")
                }
            }
        }
    }

    /// A string's translations: one unit, or one for each plural or device form.
    static func units(in localization: [String: Any]) -> [[String: Any]] {
        if let unit = localization["stringUnit"] as? [String: Any] {
            return [unit]
        }
        guard let variations = localization["variations"] as? [String: Any] else { return [] }
        return variations.values.compactMap { $0 as? [String: Any] }.flatMap { forms in
            forms.values.compactMap { ($0 as? [String: Any]) }.flatMap(units(in:))
        }
    }

    @Test func aPinnedLanguageIsEnglish() {
        #expect(Words.text("System") == "System")
        #expect(AppLanguage.english.title == "English")
        #expect(AppLanguage.spanish.title == "Español")
    }
}
