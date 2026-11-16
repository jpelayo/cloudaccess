// Apache 2 license - developer@infinitecontext.com

import AVFoundation
import AVKit
import CloudCore
import Combine
import Foundation
import MediaStream
import RemoteEngine
import SwiftUI
import UIKit
import VLCPlayback

/// What the player opens: a file read live from its drive, or a copy already on this phone.
struct PlaySource: Identifiable {
    enum Origin {
        case live(engine: RemoteEngine, item: RemoteItem, connection: Connection)
        case local(URL)
    }

    let id = UUID()
    let name: String
    let origin: Origin
    /// How a person chose to play this file, from its row.
    let playback: FilePlayback
    /// Saves a change made while it plays, such as its aspect ratio, for that file.
    let remember: (FilePlayback) -> Void

    static func live(
        _ item: RemoteItem, engine: RemoteEngine, connection: Connection,
        playback: FilePlayback, remember: @escaping (FilePlayback) -> Void
    ) -> PlaySource {
        PlaySource(
            name: item.path.name, origin: .live(engine: engine, item: item, connection: connection),
            playback: playback, remember: remember)
    }

    static func local(
        _ file: URL, playback: FilePlayback, remember: @escaping (FilePlayback) -> Void
    ) -> PlaySource {
        PlaySource(name: file.lastPathComponent, origin: .local(file), playback: playback, remember: remember)
    }
}

/// The downloaded file that's playing, which removing expired downloads leaves alone.
enum PlayingNow {
    static var file: URL?
}

/// A film or sound, full screen. A file on the phone opens directly. One on a drive is served to
/// the player from inside the app (`LoopbackServer`), read piece by piece as it plays, so it starts
/// at once and can jump anywhere, encrypted drives too. The file's first bytes decide the player
/// (`MediaContainer`), and stop anything that isn't media, whatever its name. Apple's player takes
/// the formats it knows, and hands anything it can't open to VLCKit.
struct PlayerView: View {
    let source: PlaySource

    @Environment(\.dismiss) private var dismiss
    @State private var phase = Phase.starting
    @State private var server: LoopbackServer?
    /// Moves on with Try Again, which starts everything afresh.
    @State private var attempt = 0

    enum Phase {
        case starting
        case apple(URL)
        case vlc(URL)
        case failed(String)
        /// Its first bytes aren't a film or sound, whatever its name says. Trying again can't help.
        case notMedia
    }

    /// A file whose first bytes are no media container.
    private struct NotMedia: Error {}

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch phase {
            case .starting:
                ProgressView()
                    .tint(.white)
            case .apple(let url):
                AppleVideoPlayer(url: url) {
                    // Apple's player can't open this one: VLCKit plays nearly anything.
                    phase = .vlc(url)
                }
                .ignoresSafeArea()
            case .vlc(let url):
                VLCPlayerScreen(url: url, name: source.name, aspectRatio: source.playback.aspectRatio, failed: failed) { ratio in
                    var changed = source.playback
                    changed.aspectRatio = ratio
                    source.remember(changed)
                }
            case .failed(let reason):
                PlaybackProblem(
                    title: "Couldn't play this file", reason: reason, tryAgain: { attempt += 1 }, close: { dismiss() })
            case .notMedia:
                PlaybackProblem(
                    title: "This isn't a video or audio file",
                    reason: String(localized: "Its name says it is, but what's inside isn't video or audio."),
                    tryAgain: nil, close: { dismiss() })
            }
        }
        .overlay(alignment: .topLeading) {
            Button("Close", systemImage: "xmark") { dismiss() }
                .labelStyle(.iconOnly)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .padding(12)
                .background(.black.opacity(0.4), in: Circle())
                .padding()
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .task(id: attempt) {
            await start()
        }
        .onDisappear {
            PlayingNow.file = nil
            let server = server
            Task { await server?.stop() }
        }
    }

    private func start() async {
        phase = .starting
        await server?.stop()
        server = nil
        Self.activateSound()
        do {
            let url: URL
            let container: MediaContainer
            switch source.origin {
            case .local(let file):
                PlayingNow.file = file
                guard let found = MediaContainer.identify(try Self.header(of: file)) else { throw NotMedia() }
                url = file
                container = found
            case .live(let engine, let item, let connection):
                let served = try await serve(item, from: engine, connection: connection)
                url = served.0
                container = served.1
            }
            // What the file really is decides, not its name.
            let chosen = PlayerChoice.player(for: container, preference: source.playback.player)
            phase = chosen == .apple ? .apple(url) : .vlc(url)
        } catch is CancellationError {
            return
        } catch is NotMedia {
            phase = .notMedia
        } catch {
            await fail(with: error)
        }
    }

    /// The first bytes of a file on this phone.
    private static func header(of file: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        return try handle.read(upToCount: MediaContainer.headerLength) ?? Data()
    }

    /// Starts the loopback server for a file on a drive, once its first bytes show it's media.
    /// Its reads have their own lane, so a download running at the same time can't freeze the picture.
    private func serve(
        _ item: RemoteItem, from engine: RemoteEngine, connection: Connection
    ) async throws -> (URL, MediaContainer) {
        let size: Int64
        if let known = item.size {
            size = known
        } else {
            size = try await engine.item(at: item.path).size ?? 0
        }
        let path = item.path
        let scratch = URL.temporaryDirectory.appendingPathComponent("Playback").appendingPathComponent(UUID().uuidString)
        let reader = StreamReader(size: size, scratch: scratch) { offset, length, destination in
            try await TransferContext.$isPlayback.withValue(true) {
                try await engine.read(path, offset: offset, length: length, to: destination)
            }
        }
        // The first piece, which the player reads first anyway, says what the file really is.
        guard let container = MediaContainer.identify(try await reader.header()) else {
            await reader.close()
            throw NotMedia()
        }
        let shownName = container.shownName(for: item.path.name)
        let started = try await LoopbackServer.start(reader: reader, fileName: shownName) { error in
            Task { @MainActor in
                AppLog.record("\(connection.displayName): playback stopped: \(Diagnostics.kind(of: error))")
                phase = .failed(await ConnectionChecks.explain(error, for: connection, device: .iPhone))
            }
        }
        server = started
        guard let url = await started.url else { throw CancellationError() }
        AppLog.record("\(connection.displayName): playing from the drive, \(container.fileExtension) container")
        return (url, container)
    }

    private func failed() {
        Task { await fail(with: nil) }
    }

    private func fail(with error: Error?) async {
        guard let error else {
            phase = .failed(String(localized: "This file couldn't be opened. It may be damaged, or in a format CloudWanderer can't play."))
            return
        }
        if case .live(_, _, let connection) = source.origin {
            phase = .failed(await ConnectionChecks.explain(error, for: connection, device: .iPhone))
        } else {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Sound plays with the ring switch off, and carries on with the screen locked.
    private static func activateSound() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setActive(true)
    }
}

/// Apple's player, with its own controls, AirPlay and picture in picture.
private struct AppleVideoPlayer: UIViewControllerRepresentable {
    let url: URL
    let cantOpen: () -> Void

    init(url: URL, cantOpen: @escaping () -> Void) {
        self.url = url
        self.cantOpen = cantOpen
    }

    final class Coordinator {
        var watch: AnyCancellable?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
        let controller = AVPlayerViewController()
        controller.player = player
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        let cantOpen = cantOpen
        context.coordinator.watch = item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { status in
                switch status {
                case .readyToPlay:
                    player.play()
                case .failed:
                    player.pause()
                    cantOpen()
                default:
                    break
                }
            }
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {}

    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: Coordinator) {
        coordinator.watch = nil
        controller.player?.pause()
        controller.player = nil
    }
}

/// VLCKit's picture, with simple controls on top that hide while a film plays. Sound alone has
/// nothing to look at, so its controls stay, under the file's name.
private struct VLCPlayerScreen: View {
    let url: URL
    let name: String
    /// The shape chosen for this file before, if any.
    let aspectRatio: AspectRatio?
    let failed: () -> Void
    /// Remembers a shape chosen here, for the next time this file plays.
    let chooseRatio: (AspectRatio?) -> Void

    @State private var player: VLCPlayer?
    @State private var showsControls = true
    @State private var scrubbing: Double?
    @State private var hiding: Task<Void, Never>?
    /// Held while a picture plays. Apple's player does this by itself; VLCKit doesn't.
    @State private var awake: UUID?

    var body: some View {
        ZStack {
            if let player {
                // VLCKit draws in a UIKit view of its own, which takes the touch before SwiftUI
                // sees it. So the picture takes no touches, and a clear layer above it does.
                VLCVideoView(player: player)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                if !player.hasVideo, player.state == .playing || player.state == .paused {
                    VStack(spacing: 12) {
                        Image(systemName: "music.note")
                            .font(.system(size: 64))
                        Text(verbatim: name)
                            .font(.headline)
                            .multilineTextAlignment(.center)
                    }
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.horizontal, 40)
                    .accessibilityHidden(true)
                }
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .onTapGesture { reveal() }
                if showsControls {
                    controls(player)
                        .transition(.opacity)
                }
                if player.state == .opening || player.state == .buffering {
                    ProgressView()
                        .tint(.white)
                        .allowsHitTesting(false)
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showsControls)
        .onAppear {
            let made = VLCPlayer(url: url, aspectRatio: aspectRatio?.rawValue)
            player = made
            made.play()
            reveal()
        }
        .onDisappear {
            hiding?.cancel()
            player?.stop()
            keepAwake(false)
        }
        .onChange(of: player?.state) { _, state in
            if state == .failed { failed() }
        }
        // Paused, ended or failed, the iPhone may lock as usual. Sound alone plays on with the
        // screen locked, so it needs no hold.
        .onChange(of: player.map { $0.isPlaying && $0.hasVideo } ?? false) { _, playing in
            keepAwake(playing)
        }
    }

    private func keepAwake(_ on: Bool) {
        if on, awake == nil {
            awake = ScreenAwake.hold()
        } else if !on, let held = awake {
            ScreenAwake.release(held)
            awake = nil
        }
    }

    /// Shows the controls, and hides them again after 3 seconds of playing.
    private func reveal() {
        showsControls = true
        hiding?.cancel()
        hiding = Task {
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled, player?.isPlaying == true, player?.hasVideo == true, scrubbing == nil {
                showsControls = false
            }
        }
    }

    private func controls(_ player: VLCPlayer) -> some View {
        VStack {
            HStack {
                Spacer()
                tracksMenu(player)
            }
            .padding()
            Spacer()
            HStack(spacing: 48) {
                Button("Back 10 seconds", systemImage: "gobackward.10") {
                    player.jump(by: -10)
                    reveal()
                }
                Group {
                    if player.isPlaying {
                        Button("Pause", systemImage: "pause.fill") {
                            player.togglePlaying()
                            reveal()
                        }
                    } else {
                        Button("Play", systemImage: "play.fill") {
                            player.togglePlaying()
                            reveal()
                        }
                    }
                }
                .font(.system(size: 44))
                Button("Forward 10 seconds", systemImage: "goforward.10") {
                    player.jump(by: 10)
                    reveal()
                }
            }
            .labelStyle(.iconOnly)
            .font(.system(size: 30))
            .foregroundStyle(.white)
            Spacer()
            scrubBar(player)
                .padding()
        }
        .background(.black.opacity(0.35))
    }

    private func scrubBar(_ player: VLCPlayer) -> some View {
        let length = max(player.duration, 1)
        let shown = scrubbing ?? player.time
        return VStack(spacing: 4) {
            Slider(
                value: Binding(get: { min(shown, length) }, set: { scrubbing = $0 }),
                in: 0...length,
                onEditingChanged: { editing in
                    if !editing, let scrubbing {
                        player.seek(to: scrubbing)
                        self.scrubbing = nil
                        reveal()
                    }
                }
            )
            .disabled(player.duration == 0)
            HStack {
                Text(verbatim: Self.clock(shown))
                Spacer()
                Text(verbatim: Self.clock(player.duration))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white)
        }
        .tint(.white)
    }

    /// The audio track, the subtitles and the picture's shape, each as a list of its own.
    @ViewBuilder
    private func tracksMenu(_ player: VLCPlayer) -> some View {
        if !player.audioTracks.isEmpty || !player.subtitleTracks.isEmpty || player.hasVideo {
            Menu {
                if !player.audioTracks.isEmpty {
                    Picker("Audio", selection: Binding(get: { player.audioTrack }, set: { player.chooseAudio($0) })) {
                        ForEach(player.audioTracks) { track in
                            Text(verbatim: track.name).tag(track.id)
                        }
                    }
                    .pickerStyle(.menu)
                }
                if !player.subtitleTracks.isEmpty {
                    Picker(
                        "Subtitles",
                        selection: Binding(get: { player.subtitleTrack }, set: { player.chooseSubtitle($0) })
                    ) {
                        Text("Off").tag(Int32(-1))
                        ForEach(player.subtitleTracks) { track in
                            Text(verbatim: track.name).tag(track.id)
                        }
                    }
                    .pickerStyle(.menu)
                }
                if player.hasVideo {
                    Picker(
                        "Aspect Ratio",
                        selection: Binding(
                            get: { player.aspectRatio.flatMap(AspectRatio.init(rawValue:)) },
                            set: { ratio in
                                player.chooseAspectRatio(ratio?.rawValue)
                                chooseRatio(ratio)
                            })
                    ) {
                        Text("As in the File").tag(AspectRatio?.none)
                        ForEach(AspectRatio.allCases, id: \.self) { ratio in
                            Text(verbatim: ratio.shown).tag(AspectRatio?.some(ratio))
                        }
                    }
                    .pickerStyle(.menu)
                }
            } label: {
                Label("Playback Options", systemImage: "slider.horizontal.3")
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(.black.opacity(0.4), in: Circle())
            }
        }
    }

    /// 1:02:03 or 4:05, as a player shows time.
    private static func clock(_ seconds: Double) -> String {
        let whole = Int(max(0, seconds))
        let hours = whole / 3600
        let minutes = whole / 60 % 60
        let rest = whole % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, rest)
            : String(format: "%d:%02d", minutes, rest)
    }
}

/// Why the film stopped, with Try Again and Close.
private struct PlaybackProblem: View {
    let title: LocalizedStringKey
    let reason: String
    /// Nil when trying again can't help.
    let tryAgain: (() -> Void)?
    let close: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: "play.slash")
        } description: {
            Text(verbatim: reason)
        } actions: {
            if let tryAgain {
                Button("Try Again", action: tryAgain)
                    .buttonStyle(.borderedProminent)
            }
            Button("Close", action: close)
                .buttonStyle(.bordered)
        }
        .foregroundStyle(.white)
    }
}

/// How long downloads stay on this phone when unused, chosen in Settings. App-wide on purpose: a
/// drive imported from the Mac carries the Mac's cache times, and those mustn't decide what this
/// phone deletes.
enum DownloadKeepTimes {
    static let mediaKey = "keepMediaDownloadsFor"
    static let otherKey = "keepOtherDownloadsFor"

    static var media: TimeInterval {
        UserDefaults.standard.object(forKey: mediaKey) as? TimeInterval ?? KeepTime.mediaDefault
    }

    static var other: TimeInterval {
        UserDefaults.standard.object(forKey: otherKey) as? TimeInterval ?? KeepTime.otherDefault
    }
}
