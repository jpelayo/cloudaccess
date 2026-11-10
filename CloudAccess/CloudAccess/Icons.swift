// Apache 2 license - developer@infinitecontext.com

import AppKit

/// Images for the menu bar, which otherwise draws everything in one colour. Red has to stay red
/// there to work as a warning.
enum Icons {
    /// A gray cloud with a red dot, for when a drive has lost its server.
    static let offlineCloud: NSImage = {
        let image = NSImage(size: NSSize(width: 22, height: 18), flipped: false) { _ in
            let gray = NSImage.SymbolConfiguration(paletteColors: [.systemGray])
            NSImage(systemSymbolName: "cloud.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(gray)?
                .draw(in: NSRect(x: 0, y: 3, width: 20, height: 14))
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: NSRect(x: 13, y: 1, width: 8, height: 8)).fill()
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = String(localized: "CloudAccess, not connected")
        return image
    }()

    /// The loop shown while a drive syncs. It's animated where it's used.
    static func syncLoop(size: CGFloat) -> NSImage {
        let style = NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
        return NSImage(
            systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: String(localized: "Syncing"))?
            .withSymbolConfiguration(style) ?? NSImage()
    }

}
