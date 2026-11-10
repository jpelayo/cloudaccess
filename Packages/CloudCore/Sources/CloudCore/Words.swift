// Apache 2 license - developer@infinitecontext.com

import Foundation

/// Words a person sees that come from this package, in English or Spanish.
///
/// The English sentence is its own key, in `Resources/<language>.lproj/Localizable.strings`, with
/// plurals in `Localizable.stringsdict`. Two rules keep diagnostics and saved text right:
/// - Text that's saved, logged or exported for support stays English. It's translated only when
///   it's shown, with `shown(_:)`, so a failure saved in one language still reads in another.
/// - Values never go into a key: `format` takes them as arguments, so one key covers every name.
public enum Words {
    /// The package's translations for the language the app shows.
    static var bundle: Bundle {
        #if DEBUG
        // Tests compare English sentences, and this Mac's shell may be Spanish, so the test
        // scripts pin the language here.
        if let pinned = ProcessInfo.processInfo.environment["CLOUDACCESS_TEST_LANGUAGE"],
           let path = Bundle.module.path(forResource: pinned, ofType: "lproj"),
           let pinnedBundle = Bundle(path: path) {
            return pinnedBundle
        }
        #endif
        return .module
    }

    /// A sentence with no values in it.
    public static func text(_ english: String) -> String {
        bundle.localizedString(forKey: english, value: english, table: nil)
    }

    /// A sentence with values, such as `format("Remove %@?", name)`. Numbers given as `Int` use
    /// `%lld`, and a key with a number may have plural forms in the strings dictionary.
    public static func format(_ english: String, _ values: CVarArg...) -> String {
        format(english, arguments: values)
    }

    /// The same, with the values already in a list.
    static func format(_ english: String, arguments values: [CVarArg]) -> String {
        String(format: text(english), locale: Locale.current, arguments: values)
    }

    /// Text saved or made in English, in the language shown now. A sentence this package wrote
    /// is found by its English words. Anything else, such as a server's own message, stays as it is.
    public static func shown(_ saved: String) -> String {
        text(saved)
    }
}

/// An error this package words itself. The English is what's saved, logged and exported, and what
/// a person sees is made from it, in the language the app shows. So a failure saved by the Mac's
/// extension in one language still reads in the app's.
public protocol WordedError: LocalizedError {
    /// The error in English, as it's saved, logged and exported.
    var englishDescription: String { get }
}

/// A sentence kept as its English key and its values, so the English that's saved and the words
/// that are shown can't drift apart.
struct Wording {
    let key: String
    let values: [CVarArg]

    init(_ key: String, _ values: CVarArg...) {
        self.key = key
        self.values = values
    }

    /// As it's saved, logged and exported. With no values the key is the sentence, and isn't read
    /// as a format, so a server's words with a % in them come through whole.
    var english: String {
        values.isEmpty ? key : String(format: key, arguments: values)
    }

    /// In the language shown now. A whole sentence with its values in, such as a common reason,
    /// can have its own translation, and that comes first.
    var shown: String {
        let whole = Words.shown(english)
        guard whole == english, !values.isEmpty else { return whole }
        return Words.format(key, arguments: values)
    }
}
