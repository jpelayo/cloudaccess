// Apache 2 license - developer@infinitecontext.com

import CloudCore
import Foundation

/// Which player opens a file. Apple's plays the formats it knows with the phone's own hardware,
/// and brings AirPlay and picture in picture. VLCKit plays the rest.
public enum PlayerKind: Equatable, Sendable {
    case apple
    case vlc
}

public enum PlayerChoice {
    /// Whether a file's row offers to play it: its name says video or audio, by the device's type
    /// database. Only a hint: pressing play reads the file's first bytes before anything plays.
    public static func isPlayable(_ name: String) -> Bool {
        MediaFiles.isMedia(name)
    }

    /// The player for what a file really is, read from its first bytes.
    public static func player(for container: MediaContainer) -> PlayerKind {
        container.isAppleNative ? .apple : .vlc
    }
}

/// The play buttons a file's row shows. Playing live and downloading first are two different
/// buttons, so it's always clear which one starts at once and which one waits for the download.
public enum PlayButton: Equatable, Sendable {
    /// Plays from the server as it goes, without downloading first.
    case playNow
    /// Downloads the whole file, then plays the copy on the phone.
    case downloadAndPlay
    /// Plays the copy already on the phone, offline too.
    case play
}

public enum PlayButtons {
    public static func shown(isPlayable: Bool, isDownloaded: Bool, isDownloading: Bool) -> [PlayButton] {
        guard isPlayable else { return [] }
        if isDownloaded { return [.play] }
        if isDownloading { return [.playNow] }
        return [.playNow, .downloadAndPlay]
    }
}
