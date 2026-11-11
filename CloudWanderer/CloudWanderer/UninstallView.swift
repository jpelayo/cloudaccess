// Apache 2 license - developer@infinitecontext.com

import CloudCore
import CloudDesign
import FileProvider
import Foundation
import Observation
import SwiftUI

/// Uninstalls CloudWanderer from this iPhone, one checked step at a time: it takes each drive out
/// of Files and deletes its password, deletes what the app keeps here, then looks again for
/// anything left. iOS keeps an app's passwords after the app is deleted, which is why this exists.
/// Nothing on a server is touched.
@MainActor @Observable
final class PhoneUninstaller {
    enum Phase: Equatable {
        case reviewing
        case running
        case failed
        case finished
    }

    private(set) var phase: Phase = .reviewing
    private(set) var run: Uninstall.Run?
    private(set) var drivesToRemove: [Connection] = []
    private(set) var orphanLocations: [String] = []
    private(set) var reviewProblem: String?
    private(set) var hasReviewed = false
    private var task: Task<Void, Never>?

    private let store = PhoneDrives.store
    private let places: FilesPlaces
    private let drives: OpenDrives

    init(places: FilesPlaces, drives: OpenDrives) {
        self.places = places
        self.drives = drives
    }

    var hasEncryptedDrives: Bool {
        drivesToRemove.contains(where: \.isEncrypted)
    }

    /// Drives holding changes other apps saved into them, which exist only on this iPhone.
    var drivesWithKeptChanges: [Connection] {
        drivesToRemove.filter { !(places.notes[$0.id]?.kept.isEmpty ?? true) }
    }

    var isRunning: Bool {
        phase == .running
    }

    /// Every store the app has kept drives in: where Files reads them, and the app's own folder
    /// from before. Deleting from both leaves nothing behind whichever was used.
    private var everyStore: [DriveStore] {
        [store, DriveStore(directory: URL.applicationSupportDirectory, keepsPasswordsOnThisDevice: true)]
            + [DriveStore.phoneShared()].compactMap { $0 }
    }

    private var offlineFolder: URL {
        URL.applicationSupportDirectory.appendingPathComponent("Offline")
    }

    // MARK: The page before

    func review() async {
        reviewProblem = nil
        defer { hasReviewed = true }
        do {
            drivesToRemove = try store.connections()
        } catch {
            reviewProblem = Uninstall.Line.cantReadDrives(error).shown
            return
        }
        do {
            let domains = try await NSFileProviderManager.domains()
            orphanLocations = Uninstall.orphanLocations(
                domains: Set(domains.map(\.identifier.rawValue)), drives: drivesToRemove)
        } catch {
            reviewProblem = Uninstall.Line.cantListLocations(error, .phone).shown
        }
    }

    func start() {
        guard phase == .reviewing, hasReviewed, reviewProblem == nil else { return }
        run = Uninstall.Run(platform: .phone, drives: drivesToRemove, orphanLocations: orphanLocations)
        // Coming back to the app mustn't put a location back between steps.
        places.isPaused = true
        resume()
    }

    func tryAgain() {
        guard phase == .failed else { return }
        run?.tryAgain()
        resume()
    }

    /// Leaves things where the failure left them. The drives not yet removed still work.
    func stopUninstalling() {
        guard phase == .failed || phase == .reviewing else { return }
        places.isPaused = false
        run = nil
        phase = .reviewing
    }

    private func resume() {
        phase = .running
        task = Task { await proceed() }
    }

    private func proceed() async {
        while let step = run?.next {
            await perform(step)
            guard let run else { return }
            if run.failedStep != nil {
                phase = .failed
                return
            }
            guard run.state(of: step).isPassed else { return }
        }
        places.isPaused = false
        phase = .finished
    }

    private func perform(_ step: Uninstall.Step) async {
        switch step {
        case .checkFirst: await checkFirst()
        case .removeDrive(let id, _): await removeDrive(id, step: step)
        case .removeOrphanLocation(let identifier): await removeLocation(identifier, step: step)
        case .deleteLocalData: await deleteLocalData()
        case .deletePasswords: deletePasswords()
        case .confirmNothingLeft: await confirmNothingLeft()
        case .waitForUploads, .stopBackgroundWork, .turnOffLaunchAtLogin:
            // The iPhone never uploads, checks nothing in the background and has no login item.
            run?.finish(step, leftovers: [], leftAs: .nothingChanged(.phone))
        }
    }

    // MARK: Steps

    private func checkFirst() async {
        run?.begin(.checkFirst)
        let saved: [Connection]
        do {
            saved = try store.connections()
        } catch {
            run?.fail(.checkFirst, reason: .cantReadDrives(error), leftAs: .nothingChanged(.phone))
            return
        }
        do {
            _ = try await NSFileProviderManager.domains()
        } catch {
            run?.fail(.checkFirst, reason: .cantListLocations(error, .phone), leftAs: .nothingChanged(.phone))
            return
        }
        run?.finish(.checkFirst, leftovers: [], note: .found(drives: saved.count), leftAs: .nothingChanged(.phone))
    }

    /// The same order as a drive's own Remove: its place in Files first, so Files isn't left
    /// asking for a password that's gone, then its record and password, then its downloads.
    private func removeDrive(_ id: UUID, step: Uninstall.Step) async {
        run?.begin(step)
        do {
            if let connection = try store.connections().first(where: { $0.id == id }) {
                for domain in try await NSFileProviderManager.domains() where domain.identifier.rawValue == id.uuidString {
                    try await NSFileProviderManager.remove(domain)
                }
                try store.remove(id: id)
                drives.forget(connection)
            }
        } catch DriveStore.StoreError.keychain(let status) {
            run?.fail(step, reason: .keychain(status), leftAs: .driveHalfRemoved(.phone))
            return
        } catch {
            let stillThere = (try? await NSFileProviderManager.domains())?
                .contains { $0.identifier.rawValue == id.uuidString } ?? true
            run?.fail(
                step, reason: .refused(error, .phone),
                leftAs: stillThere ? .driveStillThere(.phone) : .driveHalfRemoved(.phone))
            return
        }
        let domains: [NSFileProviderDomain]
        do {
            domains = try await NSFileProviderManager.domains()
        } catch {
            run?.fail(step, reason: .cantListLocations(error, .phone), leftAs: .driveHalfRemoved(.phone))
            return
        }
        var leftovers: [Uninstall.Leftover] = []
        if domains.contains(where: { $0.identifier.rawValue == id.uuidString }) {
            leftovers.append(.location(id.uuidString))
        }
        if (try? store.connections())?.contains(where: { $0.id == id }) != false {
            leftovers.append(.record)
        }
        if !store.hasNoPassword(for: id) {
            leftovers.append(.password)
        }
        let leftAs: Uninstall.Line = leftovers.contains(.location(id.uuidString))
            ? .driveStillThere(.phone) : .driveHalfRemoved(.phone)
        run?.finish(step, leftovers: leftovers, note: .removed(.phone), leftAs: leftAs)
    }

    private func removeLocation(_ identifier: String, step: Uninstall.Step) async {
        run?.begin(step)
        do {
            for domain in try await NSFileProviderManager.domains() where domain.identifier.rawValue == identifier {
                try await NSFileProviderManager.remove(domain)
            }
        } catch {
            run?.fail(step, reason: .refused(error, .phone), leftAs: .locationStillThere(.phone))
            return
        }
        let stillThere = (try? await NSFileProviderManager.domains())?
            .contains { $0.identifier.rawValue == identifier } ?? true
        run?.finish(
            step, leftovers: stillThere ? [.location(identifier)] : [], note: .locationRemoved,
            leftAs: .locationStillThere(.phone))
    }

    private func deleteLocalData() async {
        run?.begin(.deleteLocalData)
        // Nothing may write a new log once it's gone. A line already on its way gets a moment.
        Diagnostics.silence()
        try? await Task.sleep(for: .milliseconds(500))
        var deleted = everyStore.reduce(0) { $0 + $1.deleteEverything().deleted }
        if FileManager.default.fileExists(atPath: offlineFolder.path),
           (try? FileManager.default.removeItem(at: offlineFolder)) != nil {
            deleted += 1
        }
        for item in Uninstall.temporaryItems(in: FileManager.default.temporaryDirectory) {
            if (try? FileManager.default.removeItem(at: item)) != nil {
                deleted += 1
            }
        }
        if let id = Bundle.main.bundleIdentifier, UserDefaults.standard.persistentDomain(forName: id) != nil {
            UserDefaults.standard.removePersistentDomain(forName: id)
            deleted += 1
        }
        run?.finish(.deleteLocalData, leftovers: dataLeft(), note: .deleted(items: deleted), leftAs: .itemsLeft(.phone))
    }

    private func deletePasswords() {
        run?.begin(.deletePasswords)
        do {
            let before = try store.passwordsLeft()
            for each in everyStore {
                try each.deleteAllPasswords()
            }
            let left = try store.passwordsLeft()
            run?.finish(
                .deletePasswords, leftovers: left > 0 ? [.passwords] : [], note: .passwordsDeleted(before - left),
                leftAs: .passwordsLeft)
        } catch DriveStore.StoreError.keychain(let status) {
            run?.fail(.deletePasswords, reason: .keychain(status), leftAs: .passwordsLeft)
        } catch {
            run?.fail(.deletePasswords, reason: .refused(error, .phone), leftAs: .passwordsLeft)
        }
    }

    private func confirmNothingLeft() async {
        run?.begin(.confirmNothingLeft)
        let domains: [NSFileProviderDomain]
        do {
            domains = try await NSFileProviderManager.domains()
        } catch {
            run?.fail(.confirmNothingLeft, reason: .cantListLocations(error, .phone), leftAs: .itemsLeft(.phone))
            return
        }
        var leftovers = domains.map { Uninstall.Leftover.location($0.identifier.rawValue) }
        if everyStore.contains(where: { !((try? $0.connections())?.isEmpty ?? false) }) {
            leftovers.append(.record)
        }
        if (try? store.passwordsLeft()) != 0 {
            leftovers.append(.passwords)
        }
        leftovers += dataLeft()
        run?.finish(.confirmNothingLeft, leftovers: leftovers, note: .nothingLeft(.phone), leftAs: .itemsLeft(.phone))
    }

    private func dataLeft() -> [Uninstall.Leftover] {
        var left: [String] = []
        for each in everyStore {
            for path in each.whatsLeft() where !left.contains(path) {
                left.append(path)
            }
        }
        if FileManager.default.fileExists(atPath: offlineFolder.path) {
            left.append(offlineFolder.path)
        }
        left += Uninstall.temporaryItems(in: FileManager.default.temporaryDirectory).map(\.path)
        if let id = Bundle.main.bundleIdentifier, !(UserDefaults.standard.persistentDomain(forName: id)?.isEmpty ?? true) {
            left.append("\(id).plist")
        }
        return left.map(Uninstall.Leftover.file)
    }
}

/// What an uninstall will remove, then the steps as they're carried out, in About's sheet.
struct UninstallView: View {
    let uninstaller: PhoneUninstaller
    /// Back to About, before anything has started.
    let close: () -> Void
    @State private var isExporting = false
    @State private var sharedReport: SharedFile?

    var body: some View {
        List {
            if let run = uninstaller.run {
                progress(run)
                steps(run)
                actions(run)
            } else {
                before
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isExporting) {
            ExportDrivesView(store: PhoneDrives.store, drives: uninstaller.drivesToRemove)
        }
        .sheet(item: $sharedReport) { shared in
            ShareSheet(file: shared.url)
        }
    }

    private var title: LocalizedStringKey {
        switch uninstaller.phase {
        case .finished: "CloudWanderer Uninstalled"
        case .running, .failed: "Uninstalling CloudWanderer"
        case .reviewing: "Uninstall CloudWanderer"
        }
    }

    // MARK: Before

    @ViewBuilder private var before: some View {
        if !uninstaller.hasReviewed {
            Section {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Reading the drives…")
                        .foregroundStyle(.secondary)
                }
            }
        } else if let problem = uninstaller.reviewProblem {
            Section {
                Text(verbatim: problem)
                    .foregroundStyle(.red)
                Text("Nothing was changed.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Button("Back", action: close)
            }
        } else {
            Section {
                if uninstaller.drivesToRemove.isEmpty && uninstaller.orphanLocations.isEmpty {
                    Text("No drives.")
                        .foregroundStyle(.secondary)
                }
                ForEach(uninstaller.drivesToRemove) { connection in
                    Text(verbatim: connection.displayName)
                }
                ForEach(uninstaller.orphanLocations, id: \.self) { _ in
                    Text("A Files location with no drive")
                        .foregroundStyle(.secondary)
                }
            } header: {
                SectionLabel("To remove")
            } footer: {
                Text("These drives will be removed from Files, and their passwords deleted from this iPhone. Files on your servers are not changed.")
            }
            if !uninstaller.drivesWithKeptChanges.isEmpty {
                Section {
                    ForEach(uninstaller.drivesWithKeptChanges) { connection in
                        Text(verbatim: connection.displayName)
                    }
                } header: {
                    SectionLabel("Changes only on this iPhone")
                } footer: {
                    Text("Attention: other apps saved changes into these drives. The drives are read-only, so the changes exist only on this iPhone, and uninstalling deletes them. Copy them somewhere else in Files first to keep them.")
                        .foregroundStyle(.orange)
                }
            }
            if uninstaller.hasEncryptedDrives {
                Section {
                    Button("Export Drives…") {
                        Task {
                            if await DrivesFileAccess.confirmOwner() {
                                isExporting = true
                            }
                        }
                    }
                } footer: {
                    Text("Attention: without its password, an encrypted drive can't be read. Export your drives first if you'll need them again.")
                        .foregroundStyle(.orange)
                }
            }
            Section {
                Button("Uninstall", role: .destructive) { uninstaller.start() }
                Button("Cancel", action: close)
            }
        }
    }

    // MARK: Running

    private func progress(_ run: Uninstall.Run) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: run.fraction)
                    .accessibilityLabel(Text("Progress"))
                Text(verbatim: summary(run))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func summary(_ run: Uninstall.Run) -> String {
        switch uninstaller.phase {
        case .reviewing, .running:
            return run.next.map { Uninstall.Step.title($0, on: .phone).shown } ?? ""
        case .failed:
            return String(localized: "A step failed. Nothing after it was done.")
        case .finished:
            return String(localized: "CloudWanderer has been removed from this iPhone.")
        }
    }

    private func steps(_ run: Uninstall.Run) -> some View {
        Section {
            ForEach(run.steps, id: \.self) { step in
                PhoneStepRow(step: step, state: run.state(of: step))
            }
        } header: {
            SectionLabel("Steps")
        }
    }

    @ViewBuilder private func actions(_ run: Uninstall.Run) -> some View {
        switch uninstaller.phase {
        case .reviewing, .running:
            EmptyView()
        case .failed:
            Section {
                Button("Try Again") { uninstaller.tryAgain() }
                Button("Stop Uninstalling") {
                    uninstaller.stopUninstalling()
                    close()
                }
                Button("Share Report…") { shareReport(run) }
            }
        case .finished:
            Section {
                Button("Share Report…") { shareReport(run) }
            } footer: {
                Text("To delete the app, touch and hold its icon, then choose Remove App.")
            }
        }
    }

    /// The report replaces the log, which is deleted, so it's written to a file to share.
    private func shareReport(_ run: Uninstall.Run) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("CloudWanderer Uninstall Report.txt")
        do {
            try run.report().write(to: file, atomically: true, encoding: .utf8)
            sharedReport = SharedFile(url: file)
        } catch {
            // Nothing else can be said: the log is gone by now.
            sharedReport = nil
        }
    }
}

/// A step, its mark, and what its check found.
private struct PhoneStepRow: View {
    let step: Uninstall.Step
    let state: Uninstall.State

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            mark
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: Uninstall.Step.title(step, on: .phone).shown)
                if let caption {
                    Text(verbatim: caption)
                        .font(.footnote)
                        .foregroundStyle(isFailed ? Color.red : Color.secondary)
                }
            }
        }
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
            nil
        case .running(let note), .passed(let note):
            note?.shown
        case .failed(let reason, let leftAs):
            reason.shown + " " + leftAs.shown
        }
    }
}
