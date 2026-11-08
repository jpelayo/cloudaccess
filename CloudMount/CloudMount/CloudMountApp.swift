// Apache 2 license - developer@infinitecontext.com

import CloudCore
import SwiftUI

@main
struct CloudMountApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    init() {
        // This may leave or wait, so it comes before anything starts working.
        LoginAgent.resolveLaunch()
        ProcessInfo.processInfo.disableAutomaticTermination("CloudMount keeps your drives up to date.")
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
    private static var cloudWander: NSWindow?

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
        show(&settings, title: "Settings", content: SettingsView().environment(drives))
    }

    static func showAddDrive(drives: Drives) {
        drives.wantsAddForm = true
        showSettings(drives: drives)
    }

    static func showDrive(_ connection: Connection, _ sheet: DriveRequest.Sheet, drives: Drives) {
        drives.request = DriveRequest(driveID: connection.id, sheet: sheet)
        showSettings(drives: drives)
    }

    static func showCloudWander() {
        show(&cloudWander, title: "CloudWander", content: CloudWanderView())
    }
}

/// Tells people about the iPhone app, and how a drive gets there.
struct CloudWanderView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("CloudWander for iPhone")
                .font(.headline)
            Text("Browse your drives on your iPhone, and download and export files from them.")
            Text("To add a drive, choose the QR icon beside it, and scan the code in CloudWander.")
                .foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(24)
        .frame(width: 340)
    }
}

enum About {
    /// A menu bar app isn't frontmost, so the panel would otherwise open behind other windows.
    @MainActor
    static func show() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: NSAttributedString(
                string: "Apache 2 licensed software\nDeveloped by InfiniteContext.com",
                attributes: [
                    .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ])
        ])
    }
}
