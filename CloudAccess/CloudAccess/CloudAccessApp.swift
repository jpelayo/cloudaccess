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

    /// Another app asked this one to quit, such as Activity Monitor or a logout. A logout, restart
    /// or shutdown says why, and a person quitting doesn't.
    @objc private func quitRequested(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        if event.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason)) != nil {
            LoginAgent.endSession()
        } else {
            LoginAgent.quit()
        }
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
        // The copy that handed over to this one had Settings open, such as to turn on launch at
        // login, so it opens again here.
        if LoginAgent.takeSettingsRequest() {
            AppWindows.showSettings(drives: drives)
        }
        #if DEBUG
        StatusPanel.current = panel
        #endif
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

    /// Lets a page close the window it's shown in.
    private final class WindowCloser {
        weak var window: NSWindow?

        func close() {
            window?.close()
        }
    }

    /// - Parameter nearTop: Opens the window near the top of the screen rather than in the middle,
    ///   so a tall sheet hanging from its title bar has the room below it.
    private static func show(_ window: inout NSWindow?, title: String, nearTop: Bool = false, content: some View) {
        watchScreens()
        if window == nil {
            let closer = WindowCloser()
            let controller = NSHostingController(
                rootView: content
                    .environment(\.closeWindow, { closer.close() })
                    .background(WindowBackdrop().ignoresSafeArea()))
            controller.sizingOptions = .preferredContentSize
            let made = NSWindow(contentViewController: controller)
            closer.window = made
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
            // The title bar is hidden under the page, so anywhere that isn't a control moves it.
            made.isMovableByWindowBackground = true
            // SwiftUI sizes a window lazily, so it's asked now, before centering, or the window
            // shows at one size and then jumps to another.
            made.updateConstraintsIfNeeded()
            made.layoutIfNeeded()
            made.center()
            if nearTop, let visible = (made.screen ?? NSScreen.main)?.visibleFrame {
                made.setFrameTopLeftPoint(NSPoint(x: made.frame.minX, y: visible.maxY - 24))
            }
            keepOnScreen(made)
            window = made
        }
        if let window {
            bringForward(window)
        }
    }

    private static var isWatchingScreens = false

    /// A screen taken away, or made smaller, can leave a window hanging off the edge with its
    /// buttons out of reach, so each of this app's windows is brought back inside.
    private static func watchScreens() {
        guard !isWatchingScreens else { return }
        isWatchingScreens = true
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                for window in NSApp.windows where window.isVisible && window.sheetParent == nil {
                    keepOnScreen(window)
                }
            }
        }
    }

    /// The frame moved, and made shorter if it must be, to fit inside its screen's visible area.
    private static func onScreen(_ frame: NSRect, of window: NSWindow) -> NSRect {
        guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return frame }
        var fitted = frame
        fitted.size.height = min(fitted.height, visible.height)
        fitted.origin.y = max(min(fitted.origin.y, visible.maxY - fitted.height), visible.minY)
        fitted.origin.x = max(min(fitted.origin.x, visible.maxX - fitted.width), visible.minX)
        return fitted
    }

    /// Brings a window that reaches past its screen back inside it.
    static func keepOnScreen(_ window: NSWindow) {
        let fitted = onScreen(window.frame, of: window)
        if fitted.integral != window.frame.integral {
            window.setFrame(fitted, display: true)
        }
    }

    /// Moves a window up, only as far as it must and never off the top of its screen, so a sheet
    /// this tall hanging from it fits with its buttons on the screen.
    /// - Returns: The room below the window for the sheet, once it's moved.
    @discardableResult
    static func makeRoom(for sheetHeight: CGFloat, in window: NSWindow) -> CGFloat {
        guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return sheetHeight }
        let top = CGFloat(PaneHeight.raisedTop(
            windowTop: Double(window.frame.maxY), sheetHeight: Double(sheetHeight), chrome: Double(Pane.sheetChrome),
            visibleBottom: Double(visible.minY), visibleTop: Double(visible.maxY)))
        if top > window.frame.maxY {
            var frame = window.frame
            frame.origin.y += top - frame.maxY
            move(window, to: frame)
        }
        return top - Pane.sheetChrome - visible.minY
    }

    /// With Reduce Motion on, or for a window not on screen yet, it doesn't animate.
    private static func move(_ window: NSWindow, to frame: NSRect) {
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

    /// A menu bar app is never frontmost, and the polite `activate()` can leave a window behind
    /// whatever was in front, which looks as if nothing happened. So this insists.
    private static func bringForward(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
    }

    static func showSettings(drives: Drives) {
        show(&settings, title: String(localized: "Settings"), nearTop: true, content: SettingsView().environment(drives))
    }

    /// Whether Settings is on screen, so a copy handing over can have the next one open it.
    static var isShowingSettings: Bool {
        settings?.isVisible == true
    }

    // MARK: Pages that take a while

    // Adding a drive and a drive's own pages are windows of their own, not sheets on Settings:
    // a window can be moved anywhere, and a sheet on a sheet couldn't be reached at all.

    private static var addDrive: NSWindow?
    private static var driveWindows: [UUID: NSWindow] = [:]
    private static var recoveryKitOffer: NSWindow?

    static func showAddDrive(drives: Drives) {
        guard !drives.isUninstalling else { return }
        // A closed form starts again empty.
        if addDrive?.isVisible != true {
            addDrive = nil
        }
        show(
            &addDrive, title: String(localized: "Add Drive"), nearTop: true,
            content: AddDriveView { saved in showRecoveryKitOffer(for: saved, drives: drives) }.environment(drives))
    }

    /// A drive's window, at the page asked for. One already open goes to that page and comes forward,
    /// keeping anything typed in it.
    static func showDrive(_ connection: Connection, _ sheet: DriveRequest.Sheet, drives: Drives) {
        var window = driveWindows[connection.id]
        if window?.isVisible == true {
            drives.request = DriveRequest(driveID: connection.id, sheet: sheet)
        } else {
            window = nil
            drives.request = nil
        }
        show(
            &window, title: connection.displayName, nearTop: true,
            content: DriveWindowView(request: DriveRequest(driveID: connection.id, sheet: sheet)).environment(drives))
        driveWindows[connection.id] = window
    }

    /// Offered once, straight after a new encrypted drive is made, because a lost password can't
    /// be recovered.
    static func showRecoveryKitOffer(for connection: Connection, drives: Drives) {
        recoveryKitOffer?.close()
        recoveryKitOffer = nil
        show(
            &recoveryKitOffer, title: String(localized: "Save a recovery kit"),
            content: RecoveryKitOffer(connection: connection).environment(drives))
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
            // The page's own size from the start, so the window never opens small and then grows.
            made.setContentSize(AboutView.size(isUninstalling: drives.uninstaller != nil))
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
        frame = onScreen(frame, of: window)
        guard frame.integral != current.integral else { return }
        move(window, to: frame)
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
