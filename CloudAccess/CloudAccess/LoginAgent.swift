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
    /// Sent by a copy that's leaving, so the one that stays shows its settings.
    static let showSettingsNotification = Notification.Name("com.infinitecontext.CloudAccess.showSettings")

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

    private static var otherCopy: pid_t? {
        let me = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .first { $0.processIdentifier != me && !$0.isTerminated }?
            .processIdentifier
    }

    // MARK: At launch

    /// Decides whether this copy should run. It returns only if it should.
    static func resolveLaunch() {
        // It's off, and this copy only started because the agent hadn't gone yet.
        if launchedByAgent, isTurningOff {
            isTurningOff = false
            try? service.unregister()
            exit(0)
        }
        let role = LaunchRole.decide(
            launchedByAgent: launchedByAgent,
            agentEnabled: status == .on,
            otherCopy: otherCopy)

        switch role {
        case .run:
            return
        case .leave(let pid):
            DistributedNotificationCenter.default().postNotificationName(
                showSettingsNotification, object: nil, deliverImmediately: true)
            NSRunningApplication(processIdentifier: pid)?.activate()
            exit(0)
        case .standBy(let pid):
            waitForExit(of: pid)
            if !ExitNote.shouldRun(afterExitOf: pid, note: readNote()) {
                exit(0)
            }
        case .handOver:
            if startAgentCopy() {
                exit(0)
            }
        }
    }

    /// Registering the agent starts its copy, because it runs at load. This app can't call
    /// `launchctl` from its sandbox, so re-registering is how it starts that copy after a Quit.
    private static func startAgentCopy() -> Bool {
        let agent = service
        do {
            try agent.unregister()
            try agent.register()
        } catch {
            return false
        }
        for _ in 0..<50 {
            if otherCopy != nil { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }

    private static func waitForExit(of pid: pid_t) {
        while kill(pid, 0) == 0 {
            Thread.sleep(forTimeInterval: 0.2)
        }
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

    /// Quit from the menu. The note stops a copy standing by from running instead.
    static func quit() {
        writeNote()
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
        let note = ExitNote(pid: ProcessInfo.processInfo.processIdentifier, reason: .quit)
        try? FileManager.default.createDirectory(
            at: URL.applicationSupportDirectory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(note).write(to: noteURL, options: .atomic)
    }

    private static func readNote() -> ExitNote? {
        (try? Data(contentsOf: noteURL)).flatMap { try? JSONDecoder().decode(ExitNote.self, from: $0) }
    }
}
