// Apache 2 license - developer@infinitecontext.com

import AppKit
#if DEBUG
import os
#endif
import CloudCore
import SwiftUI
import Symbols

/// Which drive's side panel is open, so its row can show it.
@MainActor @Observable
final class PanelState {
    var openDrive: UUID?
}

/// A borderless window that behaves like a menu: it floats above everything, takes the keyboard
/// without making the app frontmost, and closes on Escape.
final class DropdownWindow: NSPanel {
    var onCancel: (() -> Void)?

    init(controller: NSViewController) {
        super.init(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        contentViewController = controller
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

/// The menu bar item and the panel it opens. The panel is the app's main screen. It's a window of
/// its own rather than a macOS menu, because a menu can't have this look, can't scroll one list
/// inside it, and opens a side menu from anywhere on a row.
@MainActor
final class StatusPanel: NSObject {
    #if DEBUG
    /// Set once the app has launched, for the test hooks.
    static var current: StatusPanel?
    #endif

    private static let autosaveName = "CloudAccess"
    /// macOS keeps each item's distance from the right of the screen here. The key isn't
    /// documented, so Command-dragging the icon stays the fallback.
    private static let positionKey = "NSStatusItem Preferred Position \(autosaveName)"
    private static let edgeGap: CGFloat = 8
    private static let sideGap: CGFloat = 6

    private let drives: Drives
    private let state = PanelState()
    private var item: NSStatusItem?
    /// Takes the cloud's place while syncing. A button can't animate its own image.
    private let syncSign = NSImageView(image: Icons.syncLoop(size: 14))
    private var panel: DropdownWindow?
    private var side: DropdownWindow?
    private var clickWatchers: [Any] = []

    init(drives: Drives) {
        self.drives = drives
        super.init()
        makeItem()
        watchConnection()
    }

    private func makeItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = Self.autosaveName
        self.item = item
        if let button = item.button {
            button.target = self
            button.action = #selector(togglePanel)
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
            syncSign.removeFromSuperview()
            syncSign.translatesAutoresizingMaskIntoConstraints = false
            syncSign.isHidden = true
            button.addSubview(syncSign)
            NSLayoutConstraint.activate([
                syncSign.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                syncSign.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            ])
        }
        updateIcon()
    }

    /// Moves the icon next to the system's own, the last place the notch hides.
    func makeVisible() {
        close()
        if let item {
            NSStatusBar.system.removeStatusItem(item)
        }
        UserDefaults.standard.set(1, forKey: Self.positionKey)
        makeItem()
    }

    /// Whether the icon can really be seen. An item the notch hides has no visible window.
    var isIconVisible: Bool {
        item?.button?.window?.occlusionState.contains(.visible) ?? false
    }

    // MARK: The icon

    /// Gray means a whole-connection problem, never a single failed file. A drive that can't be
    /// reached isn't syncing, so that comes first. A triangle means files are waiting for a person,
    /// and it stays above the turning sign, so that sign can never hide them.
    private func updateIcon() {
        guard let button = item?.button else { return }
        let needsHelp = drives.needsHelp && !drives.hasConnectionProblem
        let isSyncing = drives.isSyncing && !drives.hasConnectionProblem && !needsHelp
        syncSign.isHidden = !isSyncing
        if isSyncing {
            syncSign.addSymbolEffect(.rotate, options: .repeat(.continuous))
            // Keeps the item's width, so the icons beside it don't shift.
            button.image = NSImage(size: NSSize(width: 18, height: 18))
        } else {
            syncSign.removeAllSymbolEffects()
            if drives.hasConnectionProblem {
                button.image = Icons.offlineCloud
            } else if needsHelp {
                let sign = NSImage(
                    systemSymbolName: "exclamationmark.triangle.fill",
                    accessibilityDescription: "CloudAccess needs attention")
                sign?.isTemplate = true
                button.image = sign
            } else {
                let cloud = NSImage(systemSymbolName: "cloud.fill", accessibilityDescription: "CloudAccess")
                cloud?.isTemplate = true
                button.image = cloud
            }
        }
    }

    private func watchConnection() {
        withObservationTracking {
            _ = drives.hasConnectionProblem
            _ = drives.isSyncing
            _ = drives.needsHelp
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.updateIcon()
                self?.watchConnection()
            }
        }
    }

    // MARK: The panel

    private var screen: NSScreen? {
        item?.button?.window?.screen ?? NSScreen.main
    }

    private var heightLimit: CGFloat {
        PanelHeight.limit(screenHeight: Double(screen?.frame.height ?? 0))
    }

    @objc private func togglePanel() {
        if panel == nil {
            open()
        } else {
            close()
        }
    }

    private func open() {
        guard let button = item?.button, let bar = button.window else { return }
        let controller = NSHostingController(
            rootView: StatusPanelView(panel: self, state: state, maxHeight: heightLimit)
                .environment(drives)
                .background(WindowBackdrop(cornerRadius: 16)))
        controller.sizingOptions = .preferredContentSize
        let window = DropdownWindow(controller: controller)
        window.onCancel = { [weak self] in self?.close() }
        let size = controller.view.fittingSize
        window.setContentSize(size)

        let icon = bar.convertToScreen(button.convert(button.bounds, to: nil))
        let visible = screen?.visibleFrame ?? icon
        let x = min(max(icon.midX - size.width / 2, visible.minX + Self.edgeGap), visible.maxX - size.width - Self.edgeGap)
        window.setFrameOrigin(NSPoint(x: x, y: icon.minY - Self.sideGap - size.height))
        window.makeKeyAndOrderFront(nil)
        panel = window
        button.highlight(true)
        watchClicks()
    }

    func close() {
        clickWatchers.forEach(NSEvent.removeMonitor)
        clickWatchers = []
        closeSide()
        panel?.orderOut(nil)
        panel = nil
        item?.button?.highlight(false)
    }

    /// Closes the panel, then acts, so what it opens isn't underneath.
    func leave(then action: () -> Void) {
        close()
        action()
    }

    /// A click anywhere else closes the panel, as it would a menu. The icon handles its own click.
    private func watchClicks() {
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        if let outside = NSEvent.addGlobalMonitorForEvents(matching: clicks, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }) {
            clickWatchers.append(outside)
        }
        if let inside = NSEvent.addLocalMonitorForEvents(matching: clicks, handler: { [weak self] event in
            if let self, let window = event.window,
               window !== self.panel, window !== self.side, window !== self.item?.button?.window {
                self.close()
            }
            return event
        }) {
            clickWatchers.append(inside)
        }
    }

    // MARK: The side panel

    /// - Parameter rowTop: How far down the panel the drive's row starts.
    func toggleSide(for connection: Connection, rowTop: CGFloat) {
        let wasOpen = state.openDrive == connection.id
        closeSide()
        guard !wasOpen, let panel else { return }
        state.openDrive = connection.id

        let controller = NSHostingController(
            rootView: DriveSidePanel(connection: connection, panel: self)
                .environment(drives)
                .background(WindowBackdrop(cornerRadius: 14)))
        controller.sizingOptions = .preferredContentSize
        let window = DropdownWindow(controller: controller)
        window.onCancel = { [weak self] in self?.closeSide() }
        let size = controller.view.fittingSize
        window.setContentSize(size)

        let visible = screen?.visibleFrame ?? panel.frame
        let fitsOnRight = panel.frame.maxX + Self.sideGap + size.width <= visible.maxX - Self.edgeGap
        let x = fitsOnRight ? panel.frame.maxX + Self.sideGap : panel.frame.minX - Self.sideGap - size.width
        let top = min(panel.frame.maxY - rowTop, visible.maxY - Self.edgeGap)
        window.setFrameOrigin(NSPoint(x: x, y: max(top - size.height, visible.minY + Self.edgeGap)))
        panel.addChildWindow(window, ordered: .above)
        window.makeKeyAndOrderFront(nil)
        side = window
    }

    private func closeSide() {
        if let side {
            panel?.removeChildWindow(side)
            side.orderOut(nil)
        }
        side = nil
        state.openDrive = nil
    }

    #if DEBUG
    /// Lays the panel out without showing it, with far more drives than anyone has, and reports
    /// how tall it came out.
    func reportLayout() {
        let real = drives.connections
        for count in [real.count, 100] where !real.isEmpty {
            let many: [Connection] = (0..<count).map { index in
                var copy = real[index % real.count]
                copy.id = UUID()
                return copy
            }
            let view = StatusPanelView(panel: self, state: state, maxHeight: heightLimit, sample: many)
                .environment(drives)
            let height = NSHostingView(rootView: view).fittingSize.height
            testReports.notice("CM_MENU: drives=\(count) height=\(height) half=\(self.heightLimit)")
        }
    }
    #endif
}
