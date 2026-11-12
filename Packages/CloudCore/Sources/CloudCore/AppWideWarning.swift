// Apache 2 license - developer@infinitecontext.com

import Foundation

/// What the whole app shows about connections. A drive that fails because of its own server says
/// so only in that drive's own places: its row, its panel, its pages. Only a problem with this
/// device, which one fix mends for every drive it touches, is shown app-wide.
public enum AppWideWarning: Equatable, Sendable {
    /// Nothing app-wide: every failure, if any, stays with its drive.
    case none
    /// A problem with this device that only some drives feel, such as Tailscale being off, and
    /// how many drives feel it. The menu bar icon and the status pill stay as they are while other
    /// drives work.
    case deviceProblem(ConnectionFinding, drives: Int)
    /// This device can't connect to anything, such as with no network at all.
    case cannotConnect(ConnectionFinding)

    /// From the findings of the drives that are offline now.
    public static func from(_ findings: [ConnectionFinding]) -> AppWideWarning {
        if let stopping = findings.first(where: \.stopsEveryDrive) {
            return .cannotConnect(stopping)
        }
        return deviceProblems(in: findings).first ?? .none
    }

    /// One warning for each problem with this device, for a list that shows them all. Tailscale
    /// comes first: it's the one a person is most likely to have just turned off.
    public static func deviceProblems(in findings: [ConnectionFinding]) -> [AppWideWarning] {
        let device = findings.filter { $0.scope == .device && !$0.stopsEveryDrive }
        var kinds: [ConnectionFinding.Kind] = []
        for finding in device where !kinds.contains(finding.kind) {
            kinds.append(finding.kind)
        }
        let ordered = kinds.filter { $0 == .tailscaleOff } + kinds.filter { $0 != .tailscaleOff }
        return ordered.compactMap { kind in
            let feeling = device.filter { $0.kind == kind }
            return feeling.first.map { AppWideWarning.deviceProblem($0, drives: feeling.count) }
        }
    }

    public var finding: ConnectionFinding? {
        switch self {
        case .none: nil
        case .deviceProblem(let finding, _), .cannotConnect(let finding): finding
        }
    }

    public var stopsEveryDrive: Bool {
        if case .cannotConnect = self { return true }
        return false
    }

    /// The app-wide row's words, in the language shown. It speaks of every drive it touches, so
    /// it names no server.
    public var title: String? {
        guard let finding else { return nil }
        let mac = finding.device == .mac
        switch self {
        case .deviceProblem(_, let drives) where finding.kind == .tailscaleOff:
            return Words.format(mac ? "Tailscale is off on this Mac. %lld drives need it."
                : "Tailscale is off on this iPhone. %lld drives need it.", drives)
        default:
            return finding.sentence
        }
    }
}
