// Apache 2 license - developer@infinitecontext.com

import Foundation

/// The language an app shows. It follows the system unless a person picks one in the app.
///
/// Apple reads the language when an app starts, so a choice applies from the next launch. It's
/// kept in the app's own defaults as `AppleLanguages`, which is where Apple's own per-app choice
/// goes, so the system's per-app language setting and this one stay the same thing.
public enum AppLanguage: String, CaseIterable, Sendable {
    case system
    case english = "en"
    case spanish = "es"

    private static let key = "AppleLanguages"

    /// A language is named in its own words, so a person can find theirs whatever is showing.
    public var title: String {
        switch self {
        case .system: Words.text("System")
        case .english: "English"
        case .spanish: "Español"
        }
    }

    /// What this app chose for itself, read from its own defaults, never the system's list.
    public static func chosen(in defaults: UserDefaults = .standard, app: String? = Bundle.main.bundleIdentifier) -> AppLanguage {
        guard let app,
              let own = defaults.persistentDomain(forName: app)?[key] as? [String],
              let first = own.first
        else { return .system }
        return AppLanguage(rawValue: String(first.prefix(2))) ?? .system
    }

    public static func choose(_ language: AppLanguage, in defaults: UserDefaults = .standard) {
        if language == .system {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set([language.rawValue], forKey: key)
        }
    }

    /// The language the running app shows, as Apple chose it at launch.
    public static var showing: String {
        Bundle.main.preferredLocalizations.first ?? "en"
    }
}
