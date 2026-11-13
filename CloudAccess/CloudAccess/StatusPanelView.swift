// Apache 2 license - developer@infinitecontext.com

import CloudCore
import CloudDesign
import SwiftUI
import SyncCore

/// A list's shape, for the column that decides how much of it shows.
struct PanelListShape {
    let rows: Int
    let rowHeight: CGFloat
    let chrome: CGFloat
}

private struct PanelList: LayoutValueKey {
    static let defaultValue: PanelListShape? = nil
}

/// Stacks the panel's parts, and gives its one growing list only the height the others leave, so
/// the panel stays under its limit and only that list scrolls.
private struct CappedColumn: Layout {
    let maxHeight: CGFloat
    let spacing: CGFloat

    private func heights(of subviews: Subviews, width: CGFloat?) -> [CGFloat] {
        let proposal = ProposedViewSize(width: width, height: nil)
        var heights = subviews.map { $0[PanelList.self] == nil ? $0.sizeThatFits(proposal).height : 0 }
        let used = heights.reduce(0, +) + spacing * CGFloat(max(subviews.count - 1, 0))
        for (index, subview) in subviews.enumerated() {
            if let shape = subview[PanelList.self] {
                heights[index] = PanelHeight.list(
                    rows: shape.rows, rowHeight: shape.rowHeight, chrome: shape.chrome,
                    available: maxHeight - used)
            }
        }
        return heights
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let all = heights(of: subviews, width: proposal.width)
        let height = all.reduce(0, +) + spacing * CGFloat(max(subviews.count - 1, 0))
        return CGSize(width: proposal.width ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var top = bounds.minY
        for (subview, height) in zip(subviews, heights(of: subviews, width: bounds.width)) {
            subview.place(
                at: CGPoint(x: bounds.minX, y: top),
                proposal: ProposedViewSize(width: bounds.width, height: height))
            top += height + spacing
        }
    }
}

/// The whole app in a word, beside its name. It opens the Information page of the drive it's
/// talking about, so the word can always be followed up.
struct OverallPill: View {
    @Environment(Drives.self) private var drives

    let open: (Connection) -> Void

    private var status: (text: String, color: Color) {
        if drives.hasConnectionProblem { return (String(localized: "Not connected"), .red) }
        if drives.connections.isEmpty { return (String(localized: "No drives"), .gray) }
        if !drives.connections.contains(where: \.isMounted) { return (String(localized: "Ejected"), .gray) }
        if drives.needsHelp { return (String(localized: "Attention"), .orange) }
        if drives.isSyncing { return (String(localized: "Syncing"), .blue) }
        // A drive whose own server fails isn't a warning for the whole app, but the app can't
        // say it's connected either.
        if drives.isPartlyConnected { return (String(localized: "Partly connected"), .gray) }
        return (String(localized: "Connected"), .green)
    }

    var body: some View {
        Button {
            if let connection = drives.driveToReport {
                open(connection)
            }
        } label: {
            StatusPill(text: status.text, color: status.color)
        }
        .buttonStyle(.plain)
        .disabled(drives.driveToReport == nil)
        .help("Show what's happening")
        .accessibilityHint("Shows what's happening on the drive")
    }
}

/// The sign beside a drive that's busy or stuck. It opens the drive's Information page.
struct DriveActivitySign: View {
    @Environment(Drives.self) private var drives

    let connection: Connection
    /// A window can stay open for hours, and a sign that turns redraws it all the while.
    var turns = true
    let open: () -> Void

    var body: some View {
        if drives.needsHelp(on: connection) {
            Button("Show what's stuck", systemImage: "exclamationmark.triangle.fill", action: open)
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(.orange)
                .help("Show what's stuck")
        } else if drives.isTransferring(connection) {
            Button(action: open) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 12))
                    .symbolEffect(.rotate, options: .repeat(.continuous), isActive: turns)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Show what's moving")
            .accessibilityLabel("Syncing")
            .accessibilityHint("Shows what's moving")
        }
    }
}

/// What a drive's row can do straight away, the same in the panel and in Settings.
struct DriveButtons: View {
    @Environment(Drives.self) private var drives

    let connection: Connection
    /// Runs each action, so the panel can close first.
    var perform: (() -> Void) -> Void = { $0() }
    let showCode: () -> Void

    /// Only on a drive that can't connect. The panel stays open, so the row shows what the check
    /// found, and polling keeps trying without it.
    private var checkAgain: some View {
        let isChecking = drives.isChecking(connection)
        return Button("Check Again", systemImage: "arrow.clockwise") {
            Task { await drives.checkAgain([connection]) }
        }
        .symbolEffect(.rotate, options: .repeat(.continuous), isActive: isChecking)
        .buttonStyle(.icon)
        .disabled(isChecking)
        .help(isChecking ? LocalizedStringKey("Checking…") : LocalizedStringKey("Check Again"))
    }

    var body: some View {
        HStack(spacing: 6) {
            Button("Show in Finder", systemImage: "magnifyingglass") {
                perform { Task { await drives.openInFinder(connection) } }
            }
            .buttonStyle(.icon)
            .disabled(!connection.isMounted)
            .help("Show in Finder")
            if drives.offline.contains(connection.id) {
                checkAgain
            }
            Button("Show QR Code", systemImage: "qrcode") {
                perform(showCode)
            }
            .buttonStyle(.icon)
            .help("Show QR Code")
            Button(
                connection.isMounted ? "Eject" : "Mount",
                systemImage: connection.isMounted ? "eject.fill" : "play.fill"
            ) {
                perform { Task { await drives.toggleMount(connection) } }
            }
            .buttonStyle(.icon)
            .help(connection.isMounted ? "Eject" : "Mount")
        }
    }
}

/// A drive in the panel. Its dot shows the state, its buttons act straight away, and its name opens
/// the side panel.
private struct PanelDriveRow: View {
    @Environment(Drives.self) private var drives

    let connection: Connection
    let panel: StatusPanel
    let state: PanelState

    @State private var rowTop: CGFloat = 0
    @State private var isHovering = false

    private var color: Color {
        switch drives.light(of: connection) {
        case .green: .green
        case .yellow: .yellow
        case .red: .red
        }
    }

    private var isOpen: Bool {
        state.openDrive == connection.id
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)
                .accessibilityLabel(drives.light(of: connection).description)
            Button {
                panel.toggleSide(for: connection, rowTop: rowTop)
            } label: {
                HStack(spacing: 6) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(connection.displayName)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        if let status = drives.statusLabel(of: connection) {
                            Text(status)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isOpen || isHovering ? Design.controlFill : .clear))
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            .accessibilityHint("Shows the drive's details and actions")
            DriveActivitySign(connection: connection) {
                panel.leave { AppWindows.showDrive(connection, .information, drives: drives) }
            }
            DriveButtons(connection: connection, perform: { panel.leave(then: $0) }) {
                AppWindows.showDrive(connection, .code, drives: drives)
            }
        }
        .frame(height: RowHeight.double)
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { rowTop = $0 }
    }
}

/// The app's main screen, opened from the menu bar. It's never taller than `maxHeight`.
struct StatusPanelView: View {
    @Environment(Drives.self) private var drives

    let panel: StatusPanel
    let state: PanelState
    let maxHeight: CGFloat
    /// Stands in for the real drives, to measure the panel with more than anyone has.
    var sample: [Connection]?

    private static let width: CGFloat = 348
    private static let padding: CGFloat = 12
    private static let listPadding: CGFloat = 4
    private static let labelHeight: CGFloat = 14

    private var shown: [Connection] {
        sample ?? drives.connections
    }

    private var version: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    var body: some View {
        CappedColumn(maxHeight: maxHeight - Self.padding * 2, spacing: Design.sectionGap) {
            PanelHeader(title: "CloudAccess", detail: version) {
                OverallPill { connection in
                    panel.leave { AppWindows.showDrive(connection, .information, drives: drives) }
                }
                Button("Add Drive", systemImage: "plus") {
                    panel.leave { AppWindows.showAddDrive(drives: drives) }
                }
                .buttonStyle(.icon)
                .help("Add Drive")
                Button("Settings", systemImage: "gearshape") {
                    panel.leave { AppWindows.showSettings(drives: drives) }
                }
                .buttonStyle(.icon)
                .help("Settings")
            }
            permissionRequests
            connectionWarning
            driveSection
            activity
            failedFiles
            Button {
                panel.leave { Task { await drives.showMountsInFinder() } }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .symbolEffect(.rotate, options: .repeat(.continuous), isActive: drives.isSyncing)
                        .accessibilityHidden(true)
                    Text("Show mounts in Finder")
                }
            }
            .buttonStyle(.bar(.blue))
            HStack(spacing: 8) {
                Tile("CloudWanderer", symbol: "iphone") {
                    panel.leave { AppWindows.showCloudWanderer() }
                }
                Tile("About", symbol: "info.circle") {
                    panel.leave { About.show() }
                }
                Tile("Quit", symbol: "power", tint: .red) {
                    LoginAgent.quit()
                }
            }
        }
        .frame(width: Self.width - Self.padding * 2)
        .padding(Self.padding)
    }

    /// Anything macOS is still waiting for comes first, because nothing works without it.
    @ViewBuilder
    private var permissionRequests: some View {
        if drives.needsEnabling {
            Card {
                IconRow("exclamationmark.triangle.fill", "Turn on CloudAccess", subtitle: "In System Settings", tint: .red) {
                    Button("Open") {
                        panel.leave { drives.openExtensionSettings() }
                    }
                    .buttonStyle(.pill)
                }
            }
        }
        if drives.loginStatus == .needsApproval {
            Card {
                IconRow("exclamationmark.triangle.fill", "Allow CloudAccess", subtitle: "In Login Items", tint: .red) {
                    Button("Open") {
                        panel.leave { LoginAgent.openLoginItems() }
                    }
                    .buttonStyle(.pill)
                }
            }
        }
    }

    @ViewBuilder
    private var connectionWarning: some View {
        if let changed = drives.connections.first(where: { drives.changedHostKeys.contains($0.id) }) {
            Card {
                IconRow(
                    "exclamationmark.shield.fill", String(localized: "Server identity changed"),
                    subtitle: changed.displayName, tint: .red
                ) {
                    Button("Review") {
                        panel.leave { AppWindows.showDrive(changed, .settings, drives: drives) }
                    }
                    .buttonStyle(.pill)
                }
            }
        }
        if let (connection, label) = drives.driveNeedingAttention {
            Card {
                IconRow(
                    "exclamationmark.triangle.fill", connection.displayName,
                    subtitle: label.prefix(1).uppercased() + label.dropFirst(), tint: .red
                ) {
                    Button("Review") {
                        panel.leave { AppWindows.showDrive(connection, .settings, drives: drives) }
                    }
                    .buttonStyle(.pill)
                }
            }
        }
        // Only a problem with this Mac is shown here. A drive whose own server fails says so on
        // its own row, and nowhere else.
        if let title = appWideTitle {
            Card {
                IconRow(
                    "exclamationmark.triangle.fill", title,
                    subtitle: String(localized: "Files on this Mac are still available."),
                    tint: drives.hasConnectionProblem ? .red : .orange
                ) {
                    CheckAgainButton(isChecking: drives.isCheckingAgain) {
                        Task { await drives.checkAgain(drives.offlineDrives) }
                    }
                    .buttonStyle(.pill)
                }
                if drives.appWideWarning.finding?.kind == .tailscaleOff, drives.hasTailscale {
                    IconRow("network", "Tailscale", subtitle: String(localized: "Turn it on, and these drives connect by themselves.")) {
                        Button("Open") {
                            panel.leave { drives.openTailscale() }
                        }
                        .buttonStyle(.pill)
                    }
                }
                if drives.appWideWarning.finding?.action == .openLocalNetworkSettings {
                    IconRow(
                        "network", String(localized: "Local Network"),
                        subtitle: String(localized: "Allow CloudAccess there, and these drives connect by themselves.")
                    ) {
                        Button("Open") {
                            panel.leave { drives.openLocalNetworkSettings() }
                        }
                        .buttonStyle(.pill)
                    }
                }
            }
        }
    }

    /// What the app-wide row says, or nil when there's nothing app-wide to say.
    private var appWideTitle: String? {
        if let title = drives.appWideWarning.title {
            return title
        }
        if drives.hasConnectionProblem, drives.storeProblem == nil {
            return String(localized: "This Mac isn't connected to a network.")
        }
        return nil
    }

    private var driveSection: some View {
        VStack(alignment: .leading, spacing: Design.labelGap) {
            SectionLabel("Drives")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if shown.isEmpty {
                        Text("No drives yet. Add one in Settings.")
                            .foregroundStyle(.secondary)
                            .frame(height: RowHeight.double)
                    }
                    ForEach(shown) { connection in
                        PanelDriveRow(connection: connection, panel: panel, state: state)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, Self.listPadding)
            }
            .cardSurface()
        }
        .layoutValue(
            key: PanelList.self,
            value: PanelListShape(
                rows: max(shown.count, 1), rowHeight: RowHeight.double,
                chrome: Self.labelHeight + Design.labelGap + Self.listPadding * 2))
    }

    @ViewBuilder
    private var activity: some View {
        if let line = drives.activityLine {
            Button {
                panel.leave { AppWindows.showDrive(line.connection, .information, drives: drives) }
            } label: {
                Card {
                    IconRow(
                        line.isStuck ? "exclamationmark.triangle.fill" : "arrow.up.circle", line.title,
                        subtitle: line.summary, tint: line.isStuck ? .orange : nil
                    ) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show which files, and why")
            .accessibilityHint("Shows which files, and why")
        }
    }

    @ViewBuilder
    private var failedFiles: some View {
        let failures = drives.allFailures
        if !failures.isEmpty {
            VStack(alignment: .leading, spacing: Design.labelGap) {
                HStack {
                    SectionLabel("\(failures.count) failed files")
                    Spacer()
                    Button("Try Again") {
                        Task { await drives.retryFailed() }
                    }
                    .buttonStyle(.pill)
                }
                BoundedList(rows: failures.count, rowHeight: RowHeight.double, visibleRows: 3) {
                    ForEach(failures) { failure in
                        Button {
                            reveal(failure)
                        } label: {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(FlattenedPackage.shownName(failure.name))
                                    .font(.system(size: 12, weight: .semibold))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(FileProblem(stored: failure.message).localized.cause)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .frame(height: RowHeight.double)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(Self.helpText(for: failure))
                        .accessibilityHint("Shows the file in Finder")
                        .contextMenu {
                            Button("Reveal in Finder") { reveal(failure) }
                        }
                    }
                }
            }
        }
    }
}

extension StatusPanelView {
    private func reveal(_ failure: SyncFailure) {
        panel.leave { Task { await drives.reveal(failure) } }
    }

    /// The file's name and the whole saved reason, in the language shown. It's built as plain
    /// text, so `help` shows it as it is.
    private static func helpText(for failure: SyncFailure) -> String {
        let problem = FileProblem(stored: failure.message).localized
        let reason = [problem.cause, problem.fix].filter { !$0.isEmpty }.joined(separator: " ")
        return "\(FlattenedPackage.shownName(failure.name)): \(reason)"
    }
}

/// Opens beside a drive's name, with what's known about the drive and what can be done with it.
struct DriveSidePanel: View {
    @Environment(Drives.self) private var drives

    let connection: Connection
    let panel: StatusPanel

    var body: some View {
        VStack(alignment: .leading, spacing: Design.sectionGap) {
            Text(connection.displayName)
                .font(.system(size: 14, weight: .bold))
                .lineLimit(1)
            CardSection("Details") {
                ForEach(drives.details(of: connection), id: \.key) { detail in
                    KeyValueRow(detail.key, detail.value)
                }
            }
            if drives.offline.contains(connection.id) {
                // This drive's own problem stays here, with what was checked.
                Text(drives.offlineMessage(of: connection))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            CardSection("Actions") {
                if drives.offline.contains(connection.id) {
                    ActionRow(drives.isChecking(connection) ? LocalizedStringKey("Checking…") : LocalizedStringKey("Check Again"), symbol: "arrow.clockwise") {
                        Task { await drives.checkAgain([connection]) }
                    }
                    .disabled(drives.isChecking(connection))
                }
                if drives.hasTailscale, drives.drivesWithTailscaleOff.contains(connection) {
                    ActionRow("Open Tailscale", symbol: "network") {
                        panel.leave { drives.openTailscale() }
                    }
                }
                // A finding fixed by changing the drive's address or port needs no row of its own:
                // Drive Settings, further down, is where that's done.
                if drives.offline.contains(connection.id),
                   drives.checks.findings[connection.id]?.action == .openLocalNetworkSettings {
                    ActionRow("Open Local Network Settings", symbol: "network") {
                        panel.leave { drives.openLocalNetworkSettings() }
                    }
                }
                ActionRow("Show in Finder", symbol: "magnifyingglass") {
                    panel.leave { Task { await drives.openInFinder(connection) } }
                }
                .disabled(!connection.isMounted)
                ActionRow(
                    connection.isMounted ? "Eject" : "Mount",
                    symbol: connection.isMounted ? "eject.fill" : "play.fill"
                ) {
                    panel.leave { Task { await drives.toggleMount(connection) } }
                }
                ActionRow("Information…", symbol: "info.circle") {
                    panel.leave { AppWindows.showDrive(connection, .information, drives: drives) }
                }
                .disabled(!connection.isMounted)
                ActionRow("Show QR Code…", symbol: "qrcode") {
                    panel.leave { AppWindows.showDrive(connection, .code, drives: drives) }
                }
                ActionRow("Deleted Files…", symbol: "trash") {
                    panel.leave { AppWindows.showDrive(connection, .deletedFiles, drives: drives) }
                }
                .disabled(!connection.isMounted)
                ActionRow("Drive Settings…", symbol: "slider.horizontal.3") {
                    panel.leave { AppWindows.showDrive(connection, .settings, drives: drives) }
                }
            }
        }
        .padding(12)
        .frame(width: 300)
    }
}

/// One action in the side panel, which lights up under the pointer as a menu row does.
private struct ActionRow: View {
    @Environment(\.isEnabled) private var isEnabled

    let title: Text
    let symbol: String
    let action: () -> Void

    @State private var isHovering = false

    /// The title is looked up in the app's strings.
    init(_ title: LocalizedStringKey, symbol: String, action: @escaping () -> Void) {
        self.title = Text(title)
        self.symbol = symbol
        self.action = action
    }

    @_disfavoredOverload
    init(_ title: some StringProtocol, symbol: String, action: @escaping () -> Void) {
        self.title = Text(verbatim: String(title))
        self.symbol = symbol
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(.blue)
                    .frame(width: 18)
                    .accessibilityHidden(true)
                title
                    .font(.system(size: 13))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .frame(height: 28)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovering && isEnabled ? Design.controlFill : .clear))
            .opacity(isEnabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
