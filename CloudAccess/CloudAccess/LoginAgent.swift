// Apache 2 license - developer@infinitecontext.com

import AppKit
import CloudCore
import ServiceManagement

/// Launch at login, through a launch agent that runs the app itself. It starts CloudAccess at
/// login and brings it back after a crash, or when macOS ends it under memory pressure.
@MainActor
enum LoginAgent {
    enum Status: Equatable {
        case on
        case off
        case needsApproval
    }

    private static let plistName = "com.infinitecontext.CloudAccess.agent.plist"
    private static let environmentKey = "CLOUDACCESS_AGENT"
    private static let turningOffKey = "launchAgentTurningOff"
    private static let showSettingsAtLaunchKey = "showSettingsAtLaunch"
    /// Sent by a copy that's leaving, so the one that stays shows its settings.
    static let showSettingsNotification = Notification.Name("com.infinitecontext.CloudAccess.showSettings")
    /// Sent by the agent's copy as it starts, so a copy opened by hand gives way to it.
    static let handOverNotification = Notification.Name("com.infinitecontext.CloudAccess.handOver")

    /// Held by the copy that runs, for as long as it runs. Copies of the app share this folder.
    private static var instanceURL: URL {
        URL.applicationSupportDirectory.appendingPathComponent("instance.lock")
    }

    /// Held by an agent's copy while it waits to take over. Only one waits.
    private static var standbyURL: URL {
        URL.applicationSupportDirectory.appendingPathComponent("standby.lock")
    }

    /// This copy's hold on `instanceURL`. The system lets go of it however the copy ends.
    private static var running: InstanceLock?

    private static var service: SMAppService {
        SMAppService.agent(plistName: plistName)
    }

    private static var noteURL: URL {
        URL.applicationSupportDirectory.appendingPathComponent("last-exit.json")
    }

    static var launchedByAgent: Bool {
        ProcessInfo.processInfo.environment[environmentKey] == "1"
    }

    /// Launch at login was turned off from the agent's own copy. Unregistering stops that copy,
    /// and every window with it, so the switch only notes it, and it happens when the copy ends.
    private static var isTurningOff: Bool {
        get { UserDefaults.standard.bool(forKey: turningOffKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: turningOffKey)
            UserDefaults.standard.synchronize()
        }
    }

    static var status: Status {
        if isTurningOff { return .off }
        return switch service.status {
        case .enabled: .on
        case .requiresApproval: .needsApproval
        default: .off
        }
    }

    private static var me: Holder {
        Holder(pid: ProcessInfo.processInfo.processIdentifier, isAgent: launchedByAgent)
    }

    private typealias Holder = InstanceLock.Holder

    // MARK: At launch

    /// Decides whether this copy should run. It returns only if it should. Only one copy ever
    /// runs: the lock decides, and a copy that finds it taken leaves or waits its turn.
    static func resolveLaunch() {
        // It's off, and this copy only started because the agent hadn't gone yet.
        if launchedByAgent, isTurningOff {
            isTurningOff = false
            try? service.unregister()
            exit(0)
        }
        // The copy that ran last, read before this one takes its place.
        let previous = InstanceLock.holder(instanceURL)
        let role = LaunchRole.decide(
            launchedByAgent: launchedByAgent,
            agentEnabled: status == .on,
            otherCopy: claim() ? nil : InstanceLock.holder(instanceURL)?.pid ?? 0)

        switch role {
        case .run:
            // A Quit means it, even when the copy that quit crashed on its way out and launchd
            // brought it back. This exit is successful, so launchd leaves it there.
            if launchedByAgent, ExitNote.isRevivalAfterQuit(previous: previous?.pid, note: readNote()) {
                exit(0)
            }
            return
        case .leave(let pid):
            DistributedNotificationCenter.default().postNotificationName(
                showSettingsNotification, object: nil, deliverImmediately: true)
            NSRunningApplication(processIdentifier: pid)?.activate()
            exit(0)
        case .standBy:
            standBy()
        case .handOver:
            if startAgentCopy() {
                exit(0)
            }
        }
    }

    /// Takes the lock, and says whether this copy is the only one.
    private static func claim() -> Bool {
        for _ in 0..<3 {
            if let lock = InstanceLock.take(instanceURL) {
                lock.record(me)
                running = lock
                return true
            }
            if InstanceLock.isHeld(instanceURL) {
                return false
            }
            // The holder ended between the two looks.
        }
        // The lock can't be used at all. Running is better than never running.
        return true
    }

    /// The agent's copy, started while another copy runs. It asks that copy to give way, and
    /// takes over once it has. Waiting on the lock needs no permission to look at the other
    /// process, which a sandboxed app doesn't have.
    private static func standBy() {
        guard let waiting = InstanceLock.takeSoon(standbyURL) else {
            // Another copy is already waiting to take over.
            exit(0)
        }
        DistributedNotificationCenter.default().postNotificationName(
            handOverNotification, object: nil, deliverImmediately: true)
        guard let lock = InstanceLock.wait(for: instanceURL) else { exit(0) }
        waiting.release()
        // The copy that just ended left its record. If it was quit on purpose, nothing takes over.
        if let ended = InstanceLock.holder(instanceURL), !ExitNote.shouldRun(afterExitOf: ended.pid, note: readNote()) {
            exit(0)
        }
        lock.record(me)
        running = lock
    }

    /// Registering the agent starts its copy, because it runs at load. This app can't call
    /// `launchctl` from its sandbox, so re-registering is how it starts that copy after a Quit.
    /// - Returns: Whether the agent's copy is waiting to take over, so this one can leave.
    private static func startAgentCopy() -> Bool {
        let agent = service
        do {
            try agent.unregister()
            try agent.register()
        } catch {
            return false
        }
        for _ in 0..<50 {
            if InstanceLock.isHeld(standbyURL) { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }

    // MARK: Handing over

    /// A copy opened by hand gives way to the agent's copy as soon as that starts, such as when
    /// launch at login is turned on or allowed. Then only one copy runs, and it's the one launchd
    /// brings back after a crash.
    /// - Parameter isBusy: Whether this copy is in the middle of something that mustn't stop, such
    ///   as an uninstall.
    static func watchForAgentCopy(isBusy: @escaping @MainActor () -> Bool) {
        guard !launchedByAgent else { return }
        DistributedNotificationCenter.default().addObserver(
            forName: handOverNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { handOverIfAsked(isBusy: isBusy) }
        }
        // Asked while this copy was still starting, before it listened.
        handOverIfAsked(isBusy: isBusy)
    }

    private static func handOverIfAsked(isBusy: @MainActor () -> Bool) {
        guard running != nil, InstanceLock.isHeld(standbyURL), !isBusy() else { return }
        // The new copy opens Settings if this one had it open.
        UserDefaults.standard.set(AppWindows.isShowingSettings, forKey: showSettingsAtLaunchKey)
        UserDefaults.standard.synchronize()
        for window in NSApp?.windows ?? [] {
            if let sheet = window.attachedSheet {
                window.endSheet(sheet)
            }
        }
        // A successful exit with no Quit note, so the agent's copy takes over.
        exit(0)
    }

    /// Whether the copy that handed over had Settings open. It's asked once, at launch.
    static func takeSettingsRequest() -> Bool {
        let wanted = UserDefaults.standard.bool(forKey: showSettingsAtLaunchKey)
        if wanted {
            UserDefaults.standard.removeObject(forKey: showSettingsAtLaunchKey)
        }
        return wanted
    }

    // MARK: The setting

    /// - Returns: `false` if the change failed, and System Settings has opened.
    @discardableResult
    static func set(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try turnOn()
            } else {
                try turnOff()
            }
            return true
        } catch {
            SMAppService.openSystemSettingsLoginItems()
            return false
        }
    }

    private static func turnOn() throws {
        if isTurningOff {
            // It never went, so there's nothing to do but forget the note.
            isTurningOff = false
            return
        }
        let agent = service
        if agent.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
            return
        }
        guard !launchedByAgent else {
            try agent.register()
            return
        }
        // This copy keeps running, so nothing on screen goes. The agent's copy stands by, takes
        // over if this one crashes, and is the one that runs from the next login.
        // A registration keeps the signature it was made with, and macOS kills a copy signed any
        // other way, so a build signed differently needs a new one.
        try? agent.unregister()
        try agent.register()
        if agent.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    private static func turnOff() throws {
        if launchedByAgent {
            isTurningOff = true
            return
        }
        let agent = service
        guard agent.status != .notRegistered else { return }
        try agent.unregister()
    }

    static func openLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }

    // MARK: Ending

    /// Kept while the app runs, because the signal is only heard while this exists.
    private static var stopRequests: DispatchSourceSignal?

    /// A request to stop, such as `kill` or a tool's Quit, counts as a Quit. Left alone it would
    /// end the process with a signal, and launchd would take that for a failure and bring it back.
    /// A force quit can't be caught, and it looks the same as macOS ending the app under memory
    /// pressure, so that still comes back. Nothing is noted here, because unregistering the agent
    /// can stop it this way too.
    static func treatStopRequestsAsQuit() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated { end() }
        }
        source.resume()
        stopRequests = source
    }

    /// Quit from the menu. The note stops a copy standing by from running instead, and a copy
    /// launchd brings back if this one crashes on its way out.
    static func quit() {
        writeNote()
        end()
    }

    /// Logging out, restarting or shutting down. That isn't a person quitting the app, so it
    /// leaves no note, and the next login starts the app however soon it comes.
    static func endSession() {
        end()
    }

    /// Set by an uninstall in the agent's own copy, where unregistering ends this process, so it
    /// can only happen as the copy ends. It's kept in memory: the app's defaults are deleted by then.
    private static var unregistersAtEnd = false

    /// The last step of an uninstall: launch at login goes, then the app does. The Quit note is
    /// written either way, so a copy standing by leaves too.
    /// - Returns: `false` if launch at login is still on, and the app is still running. In the
    ///   agent's own copy it can't be checked, because turning it off ends the copy.
    static func uninstallAndQuit() -> Bool {
        if launchedByAgent {
            unregistersAtEnd = true
        } else if isRegistered {
            do {
                try service.unregister()
            } catch {
                return false
            }
            guard !isRegistered else { return false }
        }
        quit()
        return true
    }

    /// Whether launch at login is registered, waiting for approval or not, for the uninstall.
    static var isRegistered: Bool {
        [.enabled, .requiresApproval].contains(service.status)
    }

    /// Whether `restart()` can bring the app back by itself.
    static var canRestart: Bool { status == .on }

    /// Ends this copy so the launch agent starts it again, for a change Apple only reads at launch,
    /// such as the language. launchd leaves a successful exit alone and brings back any other, so
    /// this exits with a code of its own and writes no Quit note.
    static func restart() {
        guard canRestart else { return }
        for window in NSApp.windows {
            if let sheet = window.attachedSheet {
                window.endSheet(sheet)
            }
        }
        exit(restartCode)
    }

    /// EX_TEMPFAIL: not a failure, and not a Quit.
    private static let restartCode: Int32 = 75

    /// An open sheet makes macOS cancel a Quit, with no sign of why, so they're closed first.
    private static func end() {
        if isTurningOff || unregistersAtEnd {
            if isTurningOff {
                isTurningOff = false
            }
            // Unregistering stops this copy with this signal, which is what's wanted by now.
            signal(SIGTERM, SIG_DFL)
            try? service.unregister()
        }
        for window in NSApp.windows {
            if let sheet = window.attachedSheet {
                window.endSheet(sheet)
            }
        }
        NSApp.terminate(nil)
        // It only returns if something refused, and a Quit has to mean it.
        exit(0)
    }

    private static func writeNote() {
        let note = ExitNote(pid: ProcessInfo.processInfo.processIdentifier, reason: .quit, date: Date())
        try? FileManager.default.createDirectory(
            at: URL.applicationSupportDirectory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(note).write(to: noteURL, options: .atomic)
    }

    private static func readNote() -> ExitNote? {
        (try? Data(contentsOf: noteURL)).flatMap { try? JSONDecoder().decode(ExitNote.self, from: $0) }
    }
}
