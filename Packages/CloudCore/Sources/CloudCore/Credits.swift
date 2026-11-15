// Apache 2 license - developer@infinitecontext.com

import Foundation

/// One piece of third-party software an app carries, with its licence in its own words.
public struct Credit: Decodable, Identifiable, Equatable, Sendable {
    public let name: String
    public let version: String
    /// The licences' short names, such as "MIT" or "Apache-2.0, MIT".
    public let licence: String
    public let text: String
    /// "macOS", "iOS" or both: what each app's engine compiles in.
    public let platforms: [String]

    public var id: String { name }
}

/// What About lists. `Credits.json` is written by `Tools/make-credits.sh` from what the engine
/// really compiles in, per platform, so it can't drift from what ships; `Scripts/check.sh` fails
/// when it's out of date.
public enum Credits {
    /// Every entry, for both apps.
    public static let all: [Credit] = {
        guard let url = Bundle.module.url(forResource: "Credits", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let credits = try? JSONDecoder().decode([Credit].self, from: data)
        else { return [] }
        return credits
    }()

    #if os(iOS)
    public static let thisPlatform = "iOS"
    #else
    public static let thisPlatform = "macOS"
    #endif

    /// The entries for the app this runs in.
    public static var forThisApp: [Credit] {
        all.filter { $0.platforms.contains(thisPlatform) }
    }
}
