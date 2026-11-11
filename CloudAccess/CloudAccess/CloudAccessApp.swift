// Apache 2 license - developer@infinitecontext.com

import CloudCore
import QuartzCore
import SwiftUI

@main
struct CloudAccessApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    init() {
        // This may leave or wait, so it comes before anything starts working.
        LoginAgent.resolveLaunch()
        ProcessInfo.processInfo.disableAutomaticTermination("CloudAccess keeps your drives up to date.")
        AppDelegate.drives = Drives()
    }

    /// Everything lives in the menu bar panel, but a SwiftUI app has to have a scene.
    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static var drives: Drives?
    /// The icon in the menu bar only lasts as long as this does.
    private var panel: StatusPanel?

    /// Opening the app while it's running reaches this copy, and no second one starts. It's the
    /// only way in when the notch hides the cloud.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if let drives = Self.drives {
            AppWindows.showSettings(drives: drives)
        }
        return false
    }

    /// Another app asked this one to quit, such as Activity Monitor or a logout.
    @objc private func quitRequested(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        LoginAgent.quit()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        LoginAgent.treatStopRequestsAsQuit()
        // This replaces AppKit's own handling, which a sheet can cancel.
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(quitRequested),
            forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEQuitApplication))
        guard let drives = Self.drives else { return }
        let panel = StatusPanel(drives: drives)
        self.panel = panel
        #if DEBUG
        StatusPanel.current = panel
        #endif
        // Not before now: it can end this copy, and there's no app to end until launch finishes.
        LoginAgent.offerOnFirstLaunch()
        // The notch can hide the icon, and then nothing shows the app is running. Give the menu
        // bar a moment to settle before judging. Settings only opens if moving it didn't help.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !panel.isIconVisible else { return }
            panel.makeVisible()
            try? await Task.sleep(for: .seconds(1))
            if !panel.isIconVisible {
                AppWindows.showSettings(drives: drives)
            }
        }
    }
}

/// The app's windows. They're plain AppKit windows, because there's no main window to hang them
/// from, and macOS no longer lets a menu bar app open the SwiftUI Settings scene on request.
@MainActor
enum AppWindows {
    private static var settings: NSWindow?
    private static var cloudWanderer: NSWindow?

    private static func show(_ window: inout NSWindow?, title: String, content: some View) {
        if window == nil {
            let controller = NSHostingController(
                rootView: content.background(WindowBackdrop().ignoresSafeArea()))
            controller.sizingOptions = .preferredContentSize
            let made = NSWindow(contentViewController: controller)
            made.title = title
            made.styleMask = [.titled, .closable, .fullSizeContentView]
            // The window is its own surface, so it shows the blur instead of a title bar.
            made.titlebarAppearsTransparent = true
            made.titleVisibility = .hidden
            made.isOpaque = false
            made.backgroundColor = .clear
            made.standardWindowButton(.miniaturizeButton)?.isHidden = true
            made.standardWindowButton(.zoomButton)?.isHidden = true
            made.isReleasedWhenClosed = false
            made.center()
            window = made
        }
        if let window {
            bringForward(window)
        }
    }

    /// A menu bar app is never frontmost, and the polite `activate()` can leave a window behind
    /// whatever was in front, which looks as if nothing happened. So this insists.
    private static func bringForward(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
    }

    static func showSettings(drives: Drives) {
        show(&settings, title: String(localized: "Settings"), content: SettingsView().environment(drives))
    }

    static func showAddDrive(drives: Drives) {
        drives.wantsAddForm = true
        showSettings(drives: drives)
    }

    static func showDrive(_ connection: Connection, _ sheet: DriveRequest.Sheet, drives: Drives) {
        drives.request = DriveRequest(driveID: connection.id, sheet: sheet)
        showSettings(drives: drives)
    }

    static func showCloudWanderer() {
        show(&cloudWanderer, title: "CloudWanderer", content: CloudWandererView())
    }

    // MARK: About

    private static var about: NSWindow?
    private static let aboutGuard = AboutCloseGuard()

    /// About, and the uninstall that starts from it. Unlike the other windows, this one is sized
    /// by hand rather than by its content, so each change of page can be animated.
    static func showAbout(drives: Drives) {
        if about == nil {
            let content = AboutView { size in fitAbout(to: size) }
                .environment(drives)
                .background(WindowBackdrop().ignoresSafeArea())
            let controller = NSHostingController(rootView: content)
            controller.sizingOptions = []
            let made = NSWindow(contentViewController: controller)
            made.title = String(localized: "About CloudAccess")
            made.styleMask = [.titled, .closable, .fullSizeContentView]
            made.titlebarAppearsTransparent = true
            made.titleVisibility = .hidden
            made.isOpaque = false
            made.backgroundColor = .clear
            made.standardWindowButton(.miniaturizeButton)?.isHidden = true
            made.standardWindowButton(.zoomButton)?.isHidden = true
            made.isReleasedWhenClosed = false
            made.delegate = aboutGuard
            made.setContentSize(NSSize(width: 340, height: 300))
            made.center()
            about = made
        }
        if let about {
            bringForward(about)
        }
    }

    /// Grows or shrinks About to fit its page. The top edge stays where it is, so the window
    /// opens downward, and it stays inside the screen. With Reduce Motion on, it doesn't animate.
    private static func fitAbout(to size: CGSize) {
        guard let window = about, size.width > 0, size.height > 0 else { return }
        let current = window.frame
        // The content fills the whole window, title bar included, so the two sizes are the same.
        var frame = NSRect(origin: .zero, size: size)
        frame.origin.x = current.midX - frame.width / 2
        frame.origin.y = current.maxY - frame.height
        if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
            frame.size.height = min(frame.height, visible.height)
            frame.origin.y = max(min(frame.origin.y, visible.maxY - frame.height), visible.minY)
            frame.origin.x = max(min(frame.origin.x, visible.maxX - frame.width), visible.minX)
        }
        guard frame.integral != current.integral else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || !window.isVisible {
            window.setFrame(frame, display: true)
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                window.animator().setFrame(frame, display: true)
            }
        }
    }
}

/// About can't close while a drive is leaving Finder: those few seconds are the only part of an
/// uninstall that has to be watched through.
@MainActor
private final class AboutCloseGuard: NSObject, NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        !(AppDelegate.drives?.uninstaller?.isRemovingDrive ?? false)
    }
}

/// Tells people about the iPhone app, and how a drive gets there.
struct CloudWandererView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("CloudWanderer for iPhone")
                .font(.headline)
            Text("Browse your drives on your iPhone, and download and export files from them.")
            Text("To add a drive, choose the QR icon beside it, and scan the code in CloudWanderer.")
                .foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(24)
        .frame(width: 340)
    }
}

enum About {
    /// The app's own About window, which also holds the uninstall. AppKit's standard panel can't.
    @MainActor
    static func show() {
        guard let drives = AppDelegate.drives else { return }
        AppWindows.showAbout(drives: drives)
    }
}
