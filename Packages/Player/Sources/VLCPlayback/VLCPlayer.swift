// Apache 2 license - developer@infinitecontext.com

import Foundation
import MobileVLCKit
import Observation
import SwiftUI
import UIKit

/// A film playing in VLCKit, with what the controls on top of it need: whether it's playing,
/// where it is, how long it is, and its sound and subtitle tracks.
@MainActor
@Observable
public final class VLCPlayer: NSObject {
    public enum State: Equatable, Sendable {
        case opening
        case buffering
        case playing
        case paused
        case ended
        case failed
    }

    /// A sound or subtitle track, as the file names it.
    public struct Track: Identifiable, Equatable, Sendable {
        public let id: Int32
        public let name: String
    }

    public private(set) var state = State.opening
    /// Seconds from the start.
    public private(set) var time: Double = 0
    /// Seconds, or 0 until the file has said.
    public private(set) var duration: Double = 0
    public private(set) var audioTracks: [Track] = []
    /// Never includes "off": the controls offer that themselves.
    public private(set) var subtitleTracks: [Track] = []
    public private(set) var audioTrack: Int32 = -1
    /// -1 when subtitles are off.
    public private(set) var subtitleTrack: Int32 = -1
    /// False for sound alone, which has no picture to show.
    public private(set) var hasVideo = false

    public var isPlaying: Bool { state == .playing || state == .buffering }

    @ObservationIgnored private let player = VLCMediaPlayer()

    public init(url: URL) {
        super.init()
        let media = VLCMedia(url: url)
        // A little more than VLC's default, for a server across the internet.
        media.addOption(":network-caching=1500")
        player.media = media
        player.delegate = self
    }

    /// Where the picture is drawn.
    public func show(in view: UIView) {
        player.drawable = view
    }

    public func play() {
        player.play()
    }

    public func pause() {
        player.pause()
    }

    public func togglePlaying() {
        isPlaying ? pause() : play()
    }

    /// Jumps by a number of seconds, back when negative.
    public func jump(by seconds: Int32) {
        if seconds < 0 {
            player.jumpBackward(-seconds)
        } else {
            player.jumpForward(seconds)
        }
    }

    public func seek(to seconds: Double) {
        player.time = VLCTime(int: Int32(max(0, seconds) * 1000))
        time = max(0, seconds)
    }

    public func chooseAudio(_ track: Int32) {
        player.currentAudioTrackIndex = track
        readTracks()
    }

    /// -1 turns subtitles off.
    public func chooseSubtitle(_ track: Int32) {
        player.currentVideoSubTitleIndex = track
        readTracks()
    }

    /// Stops playing and lets go of the picture. Call it when the player closes.
    public func stop() {
        player.stop()
        player.delegate = nil
        player.drawable = nil
    }

    private func readState() {
        switch player.state {
        case .opening: state = .opening
        case .buffering: state = player.isPlaying ? .playing : .buffering
        case .playing: state = .playing
        case .paused: state = .paused
        case .ended, .stopped: state = state == .opening ? .failed : .ended
        case .error: state = .failed
        @unknown default: break
        }
        hasVideo = player.hasVideoOut
        readTracks()
    }

    private func readTime() {
        time = Double(player.time.intValue) / 1000
        hasVideo = player.hasVideoOut
        if let length = player.media?.length.intValue, length > 0 {
            duration = Double(length) / 1000
        }
    }

    private func readTracks() {
        audioTracks = Self.tracks(names: player.audioTrackNames, indexes: player.audioTrackIndexes)
        subtitleTracks = Self.tracks(names: player.videoSubTitlesNames, indexes: player.videoSubTitlesIndexes)
        audioTrack = player.currentAudioTrackIndex
        subtitleTrack = player.currentVideoSubTitleIndex
    }

    /// VLC lists "off" as track -1, which the controls offer in their own words.
    private static func tracks(names: [Any], indexes: [Any]) -> [Track] {
        zip(indexes, names).compactMap { index, name in
            guard let id = (index as? NSNumber)?.int32Value, id >= 0 else { return nil }
            return Track(id: id, name: name as? String ?? "\(id)")
        }
    }
}

extension VLCPlayer: VLCMediaPlayerDelegate {
    nonisolated public func mediaPlayerStateChanged(_ aNotification: Notification) {
        Task { @MainActor in self.readState() }
    }

    nonisolated public func mediaPlayerTimeChanged(_ aNotification: Notification) {
        Task { @MainActor in self.readTime() }
    }
}

/// The picture of a `VLCPlayer`.
public struct VLCVideoView: UIViewRepresentable {
    let player: VLCPlayer

    public init(player: VLCPlayer) {
        self.player = player
    }

    public func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        player.show(in: view)
        return view
    }

    public func updateUIView(_ view: UIView, context: Context) {}
}
