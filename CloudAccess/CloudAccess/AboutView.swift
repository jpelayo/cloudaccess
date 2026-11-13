// Apache 2 license - developer@infinitecontext.com

import AppKit
import CloudCore
import CloudDesign
import SwiftUI

/// About CloudAccess, and the uninstall that starts from it. The window changes size to fit each
/// page, so the steps, their checks and every message are on screen at once, with no scrolling
/// but the list of steps.
struct AboutView: View {
    @Environment(Drives.self) private var drives
    /// Tells the window the size this page needs.
    let fit: (CGSize) -> Void

    private var width: CGFloat {
        drives.uninstaller == nil ? 340 : 480
    }

    var body: some View {
        page
            .padding(.horizontal, 20)
            .padding(.top, 28)
            .padding(.bottom, 20)
            .frame(width: width)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { fit($0) }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            // The window is sized to this content, title bar included, as Settings is. Left in the
            // safe area, the content sat 28 points lower than measured, and the bottom margin and
            // the edge of the last card fell outside the window.
            .ignoresSafeArea(.container, edges: .top)
    }

    @ViewBuilder private var page: some View {
        if let uninstaller = drives.uninstaller {
            if uninstaller.run == nil {
                BeforeUninstallPage(uninstaller: uninstaller)
            } else {
                UninstallingPage(uninstaller: uninstaller)
            }
        } else {
            AboutPage()
        }
    }
}

/// The app's name, version and licence, and the way to remove it.
private struct AboutPage: View {
    @Environment(Drives.self) private var drives

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    var body: some View {
        VStack(spacing: Design.sectionGap) {
            VStack(spacing: 4) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                    .accessibilityHidden(true)
                Text(verbatim: "CloudAccess")
                    .font(.system(size: 15, weight: .bold))
                Text("Version \(version)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 2) {
                Text("Apache 2 licensed software")
                Text("Developed by InfiniteContext.com")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            Card {
                IconRow(
                    "trash", "Uninstall CloudAccess",
                    subtitle: "Removes your drives and their passwords from this Mac. Files on your servers are not changed."
                ) {
                    Button("Uninstall…") {
                        let uninstaller = drives.beginUninstall()
                        Task { await uninstaller.review() }
                    }
                    .buttonStyle(.pill)
                }
            }
        }
    }
}

/// What an uninstall will remove, before anything is removed.
private struct BeforeUninstallPage: View {
    @Environment(Drives.self) private var drives
    let uninstaller: Uninstaller
    @State private var isExporting = false

    var body: some View {
        VStack(alignment: .leading, spacing: Design.sectionGap) {
            Text("Uninstall CloudAccess")
                .font(.system(size: 15, weight: .bold))
            if !uninstaller.hasReviewed {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Reading the drives…")
                        .foregroundStyle(.secondary)
                }
            } else if let problem = uninstaller.reviewProblem {
                Text(verbatim: problem)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Nothing was changed.")
                    .foregroundStyle(.secondary)
            } else {
                Text("These drives will be removed from Finder, and their passwords deleted from this Mac. Files on your servers are not changed.")
                    .fixedSize(horizontal: false, vertical: true)
                BoundedList(rows: rowCount, rowHeight: RowHeight.single, visibleRows: 6) {
                    if rowCount == 0 {
                        Text("No drives.")
                            .foregroundStyle(.secondary)
                            .frame(height: RowHeight.single)
                    }
                    ForEach(uninstaller.drivesToRemove) { connection in
                        ListRow(height: RowHeight.single) {
                            Text(verbatim: connection.displayName)
                        } controls: {
                            if connection.isEncrypted {
                                Text("encrypted")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    ForEach(uninstaller.orphanLocations, id: \.self) { _ in
                        ListRow(height: RowHeight.single) {
                            Text("A Finder location with no drive")
                                .foregroundStyle(.secondary)
                        } controls: {
                            EmptyView()
                        }
                    }
                }
                Text("Before anything is removed, CloudAccess waits for every file to finish uploading.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if uninstaller.hasEncryptedDrives {
                    Text("Attention: without its password, an encrypted drive can't be read. Export your drives or save each recovery kit first.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Export Drives…") {
                        Task {
                            if await DrivesFileAccess.confirmOwner() {
                                isExporting = true
                            }
                        }
                    }
                    .buttonStyle(.bar(.blue))
                    .disabled(drives.exportable.isEmpty)
                }
            }
            VStack(spacing: 8) {
                if uninstaller.hasReviewed, uninstaller.reviewProblem == nil {
                    Button("Uninstall") { uninstaller.start() }
                        .buttonStyle(.bar(.red))
                }
                Button("Cancel") { uninstaller.cancel() }
                    .buttonStyle(.bar(.secondary))
                    .keyboardShortcut(.cancelAction)
            }
        }
        .sheet(isPresented: $isExporting) {
            ExportDrivesView(drives: drives.exportable)
                .presentationBackground(.regularMaterial)
                .presentationSizing(.fitted)
        }
    }

    private var rowCount: Int {
        uninstaller.drivesToRemove.count + uninstaller.orphanLocations.count
    }
}

/// The steps as they're carried out, each with what its check found.
private struct UninstallingPage: View {
    let uninstaller: Uninstaller
    @State private var report: TextFile?

    var body: some View {
        if let run = uninstaller.run {
            VStack(alignment: .leading, spacing: Design.sectionGap) {
                Group {
                    if uninstaller.phase == .finished {
                        Text("CloudAccess Uninstalled")
                    } else {
                        Text("Uninstalling CloudAccess")
                    }
                }
                .font(.system(size: 15, weight: .bold))
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: run.fraction)
                        .progressViewStyle(.linear)
                        .accessibilityLabel(Text("Progress"))
                    Text(verbatim: summary(run))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                BoundedList(rows: run.steps.count, rowHeight: StepRow.height, visibleRows: 8) {
                    ForEach(run.steps, id: \.self) { step in
                        StepRow(step: step, state: run.state(of: step), loginItemLeft: uninstaller.loginItemLeft)
                    }
                }
                if !run.holds.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(run.holds, id: \.english) { hold in
                            Text(verbatim: hold.shown)
                        }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                actions(run)
            }
            .savesText($report, named: "CloudAccess Uninstall Report.txt")
        }
    }

    /// One line on what's happening, or what happened.
    private func summary(_ run: Uninstall.Run) -> String {
        switch uninstaller.phase {
        case .reviewing, .running:
            if let step = run.next {
                return Uninstall.Step.title(step, on: .mac).shown
            }
            return ""
        case .paused:
            return String(localized: "Stopped. The drives not yet removed are still on this Mac and working.")
        case .failed:
            return String(localized: "A step failed. Nothing after it was done.")
        case .finished:
            return uninstaller.loginItemLeft
                ? String(localized: "Launch at login couldn't be turned off. Turn it off in Login Items.")
                : String(localized: "CloudAccess has been removed from this Mac.")
        }
    }

    @ViewBuilder private func actions(_ run: Uninstall.Run) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            switch uninstaller.phase {
            case .reviewing, .running:
                if uninstaller.canCancel {
                    Button("Cancel") { uninstaller.cancel() }
                        .buttonStyle(.bar(.secondary))
                } else if isRemovingDrives(run) {
                    Button("Stop After This Drive") { uninstaller.stopAfterThisDrive() }
                        .buttonStyle(.bar(.secondary))
                }
            case .paused:
                Button("Continue Uninstalling") { uninstaller.continueRun() }
                    .buttonStyle(.bar(.red))
                Button("Stop Uninstalling") { uninstaller.stopUninstalling() }
                    .buttonStyle(.bar(.secondary))
            case .failed:
                Button("Try Again") { uninstaller.tryAgain() }
                    .buttonStyle(.bar(.blue))
                if uninstaller.canStopUninstalling {
                    Button("Stop Uninstalling") { uninstaller.stopUninstalling() }
                        .buttonStyle(.bar(.secondary))
                }
                Button("Save Report…") { report = TextFile(text: run.report()) }
                    .buttonStyle(.bar(.secondary))
            case .finished:
                ForEach(run.keptFiles, id: \.self) { path in
                    Button("Show Kept Files: \(URL(fileURLWithPath: path).lastPathComponent)") {
                        uninstaller.reveal(path)
                    }
                    .buttonStyle(.bar(.blue))
                    .help(Text(verbatim: path))
                }
                Button("Save Report…") { report = TextFile(text: run.report()) }
                    .buttonStyle(.bar(.secondary))
                Button("Show CloudAccess in Finder") { uninstaller.showAppInFinder() }
                    .buttonStyle(.bar(.secondary))
                if uninstaller.loginItemLeft {
                    Button("Open Login Items") { LoginAgent.openLoginItems() }
                        .buttonStyle(.bar(.blue))
                    Button("Quit CloudAccess") { uninstaller.quitLeavingLoginItem() }
                        .buttonStyle(.bar(.secondary))
                } else {
                    Text("Quit, then move CloudAccess from Applications to the Bin. macOS keeps the app's own folders in your Library, with nothing of your drives in them.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Quit CloudAccess") { uninstaller.quit() }
                        .buttonStyle(.bar(.red))
                }
            }
        }
    }

    private func isRemovingDrives(_ run: Uninstall.Run) -> Bool {
        switch run.next {
        case .removeDrive?, .removeOrphanLocation?: true
        default: false
        }
    }
}

/// A step, its mark, and what its check found.
private struct StepRow: View {
    static let height: CGFloat = 48
    let step: Uninstall.Step
    let state: Uninstall.State
    let loginItemLeft: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            mark
                .frame(width: 16, height: 16)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: Uninstall.Step.title(step, on: .mac).shown)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let caption {
                    Text(verbatim: caption)
                        .font(.system(size: 11))
                        .foregroundStyle(isFailed ? Color.red : Color.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .help(Text(verbatim: caption))
                }
            }
            Spacer(minLength: 0)
        }
        .frame(height: Self.height, alignment: .top)
        .padding(.top, 4)
        .accessibilityElement(children: .combine)
    }

    private var isFailed: Bool {
        if case .failed = state { true } else { false }
    }

    @ViewBuilder private var mark: some View {
        switch state {
        case .pending:
            Image(systemName: "circle")
                .foregroundStyle(.tertiary)
                .accessibilityLabel(Text("Not done"))
        case .running:
            ProgressView()
                .controlSize(.mini)
                .accessibilityLabel(Text("Running"))
        case .passed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityLabel(Text("Passed"))
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .accessibilityLabel(Text("Failed"))
        }
    }

    private var caption: String? {
        switch state {
        case .pending:
            return step == .turnOffLaunchAtLogin ? Uninstall.Line.turnsOffAtQuit.shown : nil
        case .running(let note), .passed(let note):
            return note?.shown
        case .failed(let reason, let leftAs):
            return reason.shown + " " + leftAs.shown
        }
    }
}
