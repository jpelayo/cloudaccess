// Apache 2 license - developer@infinitecontext.com

import CloudCore
import CloudDesign
import SwiftUI

/// What the top of a drive's Information page says: what's happening, why, what it means for the
/// files on this Mac, and the one thing to press. It's worked out in one place, so the card only
/// lays it out, and a message is never shown twice.
struct DriveStatus {
    /// The icon's color says who has to act, so a server that's down never reads like an alarm.
    enum Tone {
        case good
        case busy
        case quiet
        /// Something's wrong, and CloudAccess waits and keeps trying.
        case waiting
        /// Only a person can mend it.
        case needsYou

        var color: Color {
            switch self {
            case .good: .green
            case .busy: .blue
            case .quiet: .secondary
            case .waiting: Color(red: 0.80, green: 0.55, blue: 0)
            case .needsYou: .orange
            }
        }
    }

    /// The button beside the title.
    enum Button {
        case checkAgain
        case tryAgain
        case mount
        case openExtensionSettings
    }

    /// A row of its own for the one change that mends it, so each row has one action.
    struct Fix {
        enum Action {
            case openGeneral
            case openTailscale
            case openLocalNetworkSettings
        }

        var symbol: String
        var title: String
        var detail: String
        var button: String
        var action: Action
    }

    var symbol: String
    var tone: Tone
    var title: String
    /// The server, on a line of its own, so the sentences never have to repeat it.
    var host: String?
    var cause: String?
    /// What it means for the files on this Mac.
    var files: String?
    var note: String?
    var button: Button?
    var fix: Fix?
    var steps: [ConnectionFinding.Step] = []
    var stepsLabel: String?
    var stepsNote: String?
}

extension Drives {
    /// Why a drive isn't connected, for its Information page and the line above its other pages.
    /// It never says more than a check or the engine proved.
    func offlineStatus(of connection: Connection) -> DriveStatus {
        let host = Self.shownHost(of: connection)
        let waits = String(localized: "Your files are still on this Mac. What you save uploads when the connection returns.")
        if let problem = problems[connection.id], problem.attentionLabel != nil {
            return signInStatus(problem, host: host)
        }
        if checks.isSettling {
            return DriveStatus(
                symbol: "arrow.clockwise", tone: .quiet, title: String(localized: "Reconnecting…"), host: host,
                cause: String(localized: "This Mac's network changed, or the Mac just woke. CloudAccess is connecting the drive again."),
                files: waits)
        }
        if let finding = checks.findings[connection.id] {
            let time = finding.checked.formatted(date: .omitted, time: .shortened)
            return DriveStatus(
                symbol: Self.symbol(for: finding), tone: finding.waitsForTheServer ? .waiting : .needsYou,
                title: finding.title, host: host, cause: finding.cause, files: waits, button: .checkAgain,
                fix: fix(for: finding), steps: finding.steps, stepsLabel: String(localized: "Checked at \(time)"),
                stepsNote: String(localized: "CloudAccess tries again every 30 seconds."))
        }
        if checks.checking.contains(connection.id) {
            return DriveStatus(
                symbol: "arrow.clockwise", tone: .quiet, title: String(localized: "Checking the connection…"), host: host,
                cause: String(localized: "CloudAccess couldn't connect, and is checking why."), files: waits,
                button: .checkAgain)
        }
        return DriveStatus(
            symbol: "icloud.slash", tone: .waiting, title: String(localized: "Not connected"), host: host, files: waits,
            button: .checkAgain)
    }

    /// The server as a person typed it: its name, and the port only when it isn't the usual one.
    static func shownHost(of connection: Connection) -> String? {
        guard let target = ConnectionCheck.Target(connection) else { return nil }
        let usual = target.isSFTP ? 22 : target.usesTLS ? 443 : 80
        return target.port == usual ? target.host : "\(target.host):\(target.port)"
    }

    private static func symbol(for finding: ConnectionFinding) -> String {
        if finding.waitsForTheServer {
            return "icloud.slash"
        }
        switch finding.kind {
        case .noNetwork, .mobileDataNotAllowed, .wifiNotAllowed: return "wifi.slash"
        case .tailscaleOff, .tailscaleBypassed, .tailnetNameUnknown: return "point.3.connected.trianglepath.dotted"
        case .localNetworkDenied, .privateAddressElsewhere: return "network"
        case .nameNotFound: return "globe"
        case .refused, .notSFTP, .notHTTPS: return "server.rack"
        case .certificateExpired, .certificateUntrusted: return "lock.trianglebadge.exclamationmark"
        default: return "exclamationmark.triangle.fill"
        }
    }

    private func fix(for finding: ConnectionFinding) -> DriveStatus.Fix? {
        let general = String(localized: "Open General")
        switch finding.action {
        case .openTailscale?:
            guard hasTailscale else { return nil }
            return DriveStatus.Fix(
                symbol: "point.3.connected.trianglepath.dotted", title: "Tailscale",
                detail: String(localized: "Turn it on, and the drive connects by itself."),
                button: String(localized: "Open Tailscale"), action: .openTailscale)
        case .openLocalNetworkSettings?:
            return DriveStatus.Fix(
                symbol: "network", title: String(localized: "Local Network"),
                detail: String(localized: "Allow CloudAccess there, and the drive connects by itself."),
                button: String(localized: "Open System Settings…"), action: .openLocalNetworkSettings)
        case .editDrive?:
            switch finding.kind {
            case .nameNotFound, .tailnetNameUnknown:
                return DriveStatus.Fix(
                    symbol: "slider.horizontal.3", title: String(localized: "Address"),
                    detail: String(localized: "Correct it in the General tab."), button: general, action: .openGeneral)
            case .refused, .notSFTP:
                return DriveStatus.Fix(
                    symbol: "slider.horizontal.3", title: String(localized: "Port"),
                    detail: String(localized: "Check it in the General tab."), button: general, action: .openGeneral)
            case .notHTTPS:
                return DriveStatus.Fix(
                    symbol: "slider.horizontal.3", title: String(localized: "Protocol and port"),
                    detail: String(localized: "Check them in the General tab."), button: general, action: .openGeneral)
            default:
                // Another network is joined on this Mac, not changed in the drive.
                return nil
            }
        case .openAppSettings?, nil:
            return nil
        }
    }

    /// A drive that reached its server and was turned away. Nothing uploads until a person acts,
    /// and the steps say the network itself is fine.
    private func signInStatus(_ problem: RemoteError, host: String?) -> DriveStatus {
        let held = String(localized: "Your files are still on this Mac. Nothing uploads until this is fixed.")
        let general = String(localized: "Open General")
        let reached = ConnectionFinding.Step(
            title: String(localized: "Connection to the server"), result: String(localized: "Works"), mark: .passed)
        let signedIn = ConnectionFinding.Step(
            title: String(localized: "Sign-in"), result: String(localized: "Accepted"), mark: .passed)
        func failed(_ title: String, _ result: String) -> ConnectionFinding.Step {
            ConnectionFinding.Step(title: title, result: result, mark: .failed)
        }
        let last = String(localized: "Last try")
        let encryption = String(localized: "Encryption")
        switch problem {
        case .unauthorized:
            return DriveStatus(
                symbol: "lock.fill", tone: .needsYou, title: String(localized: "The server refuses the sign-in"),
                host: host, cause: String(localized: "The user name or password is no longer valid."), files: held,
                fix: DriveStatus.Fix(
                    symbol: "key", title: String(localized: "Password"),
                    detail: String(localized: "Enter it again in the General tab."), button: general, action: .openGeneral),
                steps: [reached, failed(String(localized: "Sign-in"), String(localized: "Refused"))], stepsLabel: last)
        case .vault(.wrongPassword):
            return DriveStatus(
                symbol: "key.fill", tone: .needsYou, title: String(localized: "The encryption password isn't right"),
                host: host,
                cause: String(localized: "The encryption password saved on this Mac can't read the files on the server."),
                files: held,
                steps: [reached, signedIn, failed(encryption, String(localized: "Wrong password"))], stepsLabel: last)
        case .vault(.retired):
            return DriveStatus(
                symbol: "key.fill", tone: .needsYou, title: String(localized: "Encrypted drive retired"), host: host,
                cause: String(localized: "This encrypted drive was retired when its encryption password changed."),
                files: held,
                steps: [reached, signedIn, failed(encryption, String(localized: "Retired"))], stepsLabel: last)
        case .hostKeyUnknown, .hostKeyChanged:
            return DriveStatus(
                symbol: "exclamationmark.shield.fill", tone: .needsYou,
                title: String(localized: "The server's identity has changed"), host: host,
                cause: String(localized: "It may have been reinstalled, or it may not be your server. Nothing connects until you decide."),
                files: held,
                fix: DriveStatus.Fix(
                    symbol: "checkmark.shield", title: String(localized: "Server's identity"),
                    detail: String(localized: "Compare the two keys in the General tab."), button: general,
                    action: .openGeneral),
                steps: [reached, failed(String(localized: "Server's identity"), String(localized: "Different"))],
                stepsLabel: last)
        case .unsupportedServer:
            return DriveStatus(
                symbol: "server.rack", tone: .needsYou, title: String(localized: "Server not supported"), host: host,
                cause: problem.localizedDescription, files: held,
                steps: [reached, signedIn, failed(String(localized: "Server features"), String(localized: "One is missing"))],
                stepsLabel: last)
        default:
            return DriveStatus(
                symbol: "exclamationmark.triangle.fill", tone: .needsYou, title: String(localized: "Attention"),
                host: host, cause: problem.localizedDescription, files: held,
                steps: [reached, failed(encryption, String(localized: "Failed"))], stepsLabel: last)
        }
    }
}

/// The card at the top of a drive's Information page. The title and its button share the top
/// line, and everything else gets the card's full width, so nothing is squeezed into a column.
struct DriveStatusCard: View {
    let status: DriveStatus
    let isChecking: Bool
    let isRetrying: Bool
    let press: (DriveStatus.Button) -> Void
    let fix: (DriveStatus.Fix.Action) -> Void
    let showLogs: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            summary
                .padding(Design.cardPadding)
            if let row = status.fix {
                Divider()
                IconRow(row.symbol, row.title, subtitle: row.detail) {
                    Button(row.button) { fix(row.action) }
                        .buttonStyle(.pill)
                }
                .padding(.horizontal, Design.cardPadding)
                .padding(.vertical, 8)
            }
            if !status.steps.isEmpty {
                Divider()
                ConnectionSteps(steps: status.steps, label: status.stepsLabel, note: status.stepsNote)
                    .padding(Design.cardPadding)
            }
            Divider()
            IconRow("doc.text", "Logs", subtitle: "A record of what happened on your drives.") {
                Button("Show Logs", action: showLogs)
                    .buttonStyle(.pill)
            }
            .padding(.horizontal, Design.cardPadding)
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: status.symbol)
                    .font(.system(size: 18))
                    .foregroundStyle(status.tone.color)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: status.title)
                        .font(.system(size: 14, weight: .semibold))
                    if let host = status.host {
                        Text(verbatim: host)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }
                Spacer(minLength: 8)
                button
            }
            Group {
                if let cause = status.cause {
                    Text(verbatim: cause)
                        .font(.system(size: 12))
                }
                if let files = status.files {
                    Label {
                        Text(verbatim: files)
                    } icon: {
                        Image(systemName: "laptopcomputer")
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }
                if let note = status.note {
                    Text(verbatim: note)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.leading, 34)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private var button: some View {
        switch status.button {
        case .checkAgain?:
            CheckAgainButton(isChecking: isChecking) { press(.checkAgain) }
                .buttonStyle(.pill)
        case .tryAgain?:
            Button("Try Again") { press(.tryAgain) }
                .buttonStyle(.pill)
                .disabled(isRetrying)
        case .mount?:
            Button("Mount") { press(.mount) }
                .buttonStyle(.pill)
        case .openExtensionSettings?:
            Button("Open System Settings…") { press(.openExtensionSettings) }
                .buttonStyle(.pill)
        case nil:
            EmptyView()
        }
    }
}

/// What a connection check went through, step by step, so the title above can be followed up: a
/// green check for each step that passed, a red triangle for the one that failed, and a gray
/// circle for each it never got to.
struct ConnectionSteps: View {
    let steps: [ConnectionFinding.Step]
    var label: String?
    var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let label {
                SectionLabel(label)
            }
            ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                HStack(spacing: 8) {
                    mark(step.mark)
                        .frame(width: 16)
                    Text(verbatim: step.title)
                        .foregroundStyle(step.mark == .notReached ? .secondary : .primary)
                    Spacer(minLength: 8)
                    Text(verbatim: step.result)
                        .fontWeight(step.mark == .failed ? .semibold : .regular)
                        .foregroundStyle(step.mark == .failed ? Color.red : Color.secondary)
                }
                .font(.system(size: 12))
            }
            if let note {
                Text(verbatim: note)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func mark(_ mark: ConnectionFinding.Step.Mark) -> some View {
        switch mark {
        case .passed:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                .accessibilityLabel(Text("Passed"))
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                .accessibilityLabel(Text("Failed"))
        case .notReached:
            Image(systemName: "circle").foregroundStyle(.secondary)
                .accessibilityLabel(Text("Not reached"))
        }
    }
}
