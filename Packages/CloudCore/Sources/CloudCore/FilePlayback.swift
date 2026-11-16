// Apache 2 license - developer@infinitecontext.com

import Foundation

/// Which player a person wants for one file. There's no choice for Apple's player: Automatic
/// already picks it wherever it can play the file, and it can't play anything else.
public enum PlayerPreference: String, Codable, Sendable, CaseIterable {
    case automatic
    case vlc
}

/// A picture shape VLCKit can force on a video that was encoded with the wrong one.
public enum AspectRatio: String, Codable, Sendable, CaseIterable {
    // VLC reads a ratio as two whole numbers, so 1.85:1 is written 185:100.
    case wide = "16:9"
    case standard = "4:3"
    case widescreen = "16:10"
    case flat = "185:100"
    case scope = "235:100"
    case square = "1:1"

    /// How the menu writes it. Only numbers, so it reads the same in every language.
    public var shown: String {
        switch self {
        case .flat: "1.85:1"
        case .scope: "2.35:1"
        default: rawValue
        }
    }
}

/// How one file plays, as a person chose it. Kept on the phone for that file, so a video encoded
/// with the wrong shape is put right once.
public struct FilePlayback: Codable, Equatable, Sendable {
    public var player: PlayerPreference
    /// Nil plays the picture in the shape the file says.
    public var aspectRatio: AspectRatio?

    public init(player: PlayerPreference = .automatic, aspectRatio: AspectRatio? = nil) {
        self.player = player
        self.aspectRatio = aspectRatio
    }
}
