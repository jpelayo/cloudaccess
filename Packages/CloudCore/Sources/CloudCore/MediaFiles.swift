// Apache 2 license - developer@infinitecontext.com

import Foundation
import UniformTypeIdentifiers

/// Whether a file holds a film or sound.
public enum MediaKind: Equatable, Sendable {
    case video
    case audio
}

/// Films and music, told apart from other files by name, without reading them. A name is only a
/// hint, so the iPhone's player confirms it from the file's first bytes (`MediaContainer`) before
/// playing. Media is kept on a device longer than other files, because someone who downloads a
/// film means to watch it later.
public enum MediaFiles {
    /// For an extension the device's type database doesn't know. Apple keeps that database, and
    /// it's what decides first; these only fill its gaps, which differ between devices: VOB and
    /// DivX are declared by VLC where it's installed, and ALAC by nothing at all.
    static let knownVideo: Set<String> = [
        "mp4", "m4v", "mov", "mkv", "webm", "avi", "wmv", "asf", "flv", "ts", "m2ts", "mts", "mpg", "mpeg",
        "ogv", "3gp", "3g2", "vob", "divx",
    ]
    static let knownAudio: Set<String> = [
        "mp3", "m4a", "m4b", "aac", "flac", "wav", "aif", "aiff", "aifc", "caf", "ogg", "oga", "opus", "wma",
        "alac", "mka",
    ]

    /// A name's extension, in lower case, or nil if it has none.
    public static func fileExtension(of name: String) -> String? {
        let ending = (name as NSString).pathExtension.lowercased()
        return ending.isEmpty ? nil : ending
    }

    /// Video or audio by the device's type database: a type that's a kind of movie or of audio.
    /// A type the database declares as something else, such as a PDF, is never media. Only an
    /// extension it doesn't know at all falls back to the lists above.
    public static func kind(of name: String) -> MediaKind? {
        guard let ending = fileExtension(of: name) else { return nil }
        if let type = UTType(filenameExtension: ending), !type.isDynamic {
            if type.conforms(to: .movie) { return .video }
            if type.conforms(to: .audio) { return .audio }
            return nil
        }
        if knownVideo.contains(ending) { return .video }
        if knownAudio.contains(ending) { return .audio }
        return nil
    }

    public static func isVideo(_ name: String) -> Bool {
        kind(of: name) == .video
    }

    public static func isMedia(_ name: String) -> Bool {
        kind(of: name) != nil
    }
}

/// The container a media file really is, read from its first bytes. A name can be wrong, so this
/// is what decides which player opens a file, and whether any does: something that isn't a media
/// container never reaches a player, whatever it's called.
public enum MediaContainer: Equatable, Sendable, CaseIterable {
    /// ISO base media: MP4, MOV, M4V, M4A, 3GP.
    case isoMedia
    case mp3
    /// AAC in ADTS frames.
    case aac
    case wav
    case aiff
    case flac
    /// Apple's Core Audio Format.
    case caf
    /// Matroska and WebM.
    case matroska
    case avi
    case ogg
    case mpegTransport
    case mpegProgram
    case flv
    /// Windows Media: WMV and WMA.
    case asf

    /// How much of a file's start `identify` needs. Every signature is in the first few hundred
    /// bytes; the rest is room for a long ID3 tag.
    public static let headerLength = 64 * 1024

    /// Apple's player opens these itself. VLCKit opens the rest, and anything Apple's player turns
    /// down, such as an MP4 with a codec it lacks.
    public var isAppleNative: Bool {
        switch self {
        case .isoMedia, .mp3, .aac, .wav, .aiff, .flac, .caf: true
        default: false
        }
    }

    /// The usual extension, for a player that goes by the name.
    public var fileExtension: String {
        switch self {
        case .isoMedia: "mp4"
        case .mp3: "mp3"
        case .aac: "aac"
        case .wav: "wav"
        case .aiff: "aiff"
        case .flac: "flac"
        case .caf: "caf"
        case .matroska: "mkv"
        case .avi: "avi"
        case .ogg: "ogg"
        case .mpegTransport: "ts"
        case .mpegProgram: "mpg"
        case .flv: "flv"
        case .asf: "wmv"
        }
    }

    /// Every extension a file in this container is commonly called.
    var fileExtensions: Set<String> {
        switch self {
        case .isoMedia: ["mp4", "m4v", "mov", "m4a", "m4b", "3gp", "3g2"]
        case .mp3: ["mp3"]
        case .aac: ["aac"]
        case .wav: ["wav"]
        case .aiff: ["aif", "aiff", "aifc"]
        case .flac: ["flac"]
        case .caf: ["caf"]
        case .matroska: ["mkv", "mka", "webm"]
        case .avi: ["avi", "divx"]
        case .ogg: ["ogg", "ogv", "oga", "opus"]
        case .mpegTransport: ["ts", "m2ts", "mts"]
        case .mpegProgram: ["mpg", "mpeg", "vob"]
        case .flv: ["flv"]
        case .asf: ["wmv", "wma", "asf"]
        }
    }

    /// The name to hand a player: the file's own when its extension fits what it really is, or
    /// one with the right extension when it doesn't, so a player that goes by the name isn't misled.
    public func shownName(for name: String) -> String {
        if let ending = MediaFiles.fileExtension(of: name), fileExtensions.contains(ending) {
            return name
        }
        return "stream." + fileExtension
    }

    /// The container whose signature starts `header`, or nil if it isn't a media file.
    public static func identify(_ header: Data) -> MediaContainer? {
        let bytes = [UInt8](header.prefix(headerLength))
        func hasText(_ text: String, at offset: Int) -> Bool {
            let wanted = Array(text.utf8)
            return bytes.count >= offset + wanted.count && Array(bytes[offset..<(offset + wanted.count)]) == wanted
        }
        func hasBytes(_ wanted: [UInt8], at offset: Int) -> Bool {
            bytes.count >= offset + wanted.count && Array(bytes[offset..<(offset + wanted.count)]) == wanted
        }

        // ISO base media starts with a box: four bytes of size, then its type. Older QuickTime
        // files have no `ftyp`, and start straight with one of these.
        if ["ftyp", "moov", "mdat", "wide", "free", "skip", "pnot"].contains(where: { hasText($0, at: 4) }) {
            return .isoMedia
        }
        if hasBytes([0x1A, 0x45, 0xDF, 0xA3], at: 0) { return .matroska }
        if hasText("RIFF", at: 0) {
            if hasText("AVI ", at: 8) { return .avi }
            if hasText("WAVE", at: 8) { return .wav }
            return nil
        }
        if hasText("FORM", at: 0), hasText("AIFF", at: 8) || hasText("AIFC", at: 8) { return .aiff }
        if hasText("OggS", at: 0) { return .ogg }
        if hasText("fLaC", at: 0) { return .flac }
        if hasText("caff", at: 0) { return .caf }
        if hasText("FLV", at: 0) { return .flv }
        if hasBytes([0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11], at: 0) { return .asf }
        if hasBytes([0x00, 0x00, 0x01, 0xBA], at: 0) { return .mpegProgram }
        // Transport streams are 188-byte packets, each starting 0x47. Blu-ray's add a 4-byte
        // timestamp in front of each. One sync byte could be chance, two in step aren't.
        if bytes.count > 188, bytes[0] == 0x47, bytes[188] == 0x47 { return .mpegTransport }
        if bytes.count > 196, bytes[4] == 0x47, bytes[196] == 0x47 { return .mpegTransport }
        if hasText("ID3", at: 0) {
            // A tag first, then the audio. Its size is four 7-bit bytes.
            guard bytes.count >= 10 else { return .mp3 }
            let size = bytes[6...9].reduce(0) { ($0 << 7) | Int($1 & 0x7F) }
            return frame(in: bytes, at: 10 + size) ?? .mp3
        }
        return frame(in: bytes, at: 0)
    }

    /// An MPEG audio frame at `offset`: 11 sync bits, then the layer. Layer 0 with 12 sync bits
    /// is AAC's ADTS framing; layers 1 to 3 are MP3 and its kin.
    private static func frame(in bytes: [UInt8], at offset: Int) -> MediaContainer? {
        guard bytes.count >= offset + 2, bytes[offset] == 0xFF, bytes[offset + 1] & 0xE0 == 0xE0 else { return nil }
        let layer = (bytes[offset + 1] >> 1) & 0x03
        if layer == 0 {
            return bytes[offset + 1] & 0xF0 == 0xF0 ? .aac : nil
        }
        return .mp3
    }
}

/// How long an unused downloaded file stays on a device. Media and other files each have their
/// own time, chosen from the same list.
public enum KeepTime {
    public static let day: TimeInterval = 86_400

    /// Half a day, 1, 3, 7, 15, 30 and 90 days.
    public static let choices: [TimeInterval] = [0.5, 1, 3, 7, 15, 30, 90].map { $0 * day }

    public static let mediaDefault: TimeInterval = 15 * day
    public static let otherDefault: TimeInterval = 3 * day

    /// A time saved by an older build, which offered other choices, moved onto this list.
    /// "Right away" becomes half a day, the old one-hour default becomes the new default, and
    /// "keep" (nil) becomes the longest choice.
    public static func fromEarlierChoice(_ saved: TimeInterval?) -> TimeInterval {
        guard let saved else { return choices[choices.count - 1] }
        if choices.contains(saved) { return saved }
        if saved == 3600 { return otherDefault }
        // The nearest choice at least as long, so a file never goes sooner than was asked.
        return choices.first { $0 >= saved } ?? choices[choices.count - 1]
    }

    /// A choice as a picker shows it: "Keep for 12 hours", "Keep for 1 day", "Keep for 15 days".
    public static func shown(_ time: TimeInterval) -> String {
        if time < day {
            return Words.format("Keep for %lld hours", Int((time / 3600).rounded()))
        }
        return Words.format("Keep for %lld days", Int((time / day).rounded()))
    }
}
