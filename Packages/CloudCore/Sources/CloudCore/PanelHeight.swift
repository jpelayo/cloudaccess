// Apache 2 license - developer@infinitecontext.com

import Foundation

/// How much room the menu bar panel gives its one list that can grow. The panel never gets taller
/// than half the screen, so a long list scrolls inside its own space and nothing else moves.
public enum PanelHeight {
    public static func limit(screenHeight: Double) -> Double {
        screenHeight / 2
    }

    /// The height for a list, which is its natural height if that fits, otherwise as many whole
    /// rows as fit, so a row is never cut in half. One row always shows, so a drive can't vanish
    /// from a very full panel.
    /// - Parameters:
    ///   - chrome: Whatever the list needs besides its rows, such as its label and padding.
    ///   - available: The height left in the panel for the list and its chrome.
    public static func list(rows: Int, rowHeight: Double, chrome: Double, available: Double) -> Double {
        let fitting = Int((available - chrome) / rowHeight)
        return chrome + Double(min(rows, max(1, fitting))) * rowHeight
    }
}

/// How tall a settings window or sheet is. It's chosen, never measured from its content, so
/// nothing that loads later can resize it. A screen too short for it makes it shorter, and what's
/// inside scrolls.
public enum PaneHeight {
    /// Room for the title bar a sheet hangs from, the gap above the window, and a margin. The
    /// Settings window opens near the top of the screen, so its sheets have the rest.
    public static let reserved: Double = 100
    /// Enough for a header, a footer and a few rows, on any screen.
    public static let minimum: Double = 320

    public static func fitting(_ ideal: Double, screenHeight: Double) -> Double {
        max(minimum, min(ideal, screenHeight - reserved))
    }

    /// How tall a sheet is, given the room between the top of the window it hangs from and the
    /// bottom of the screen. A window can be anywhere, so the whole screen's height says nothing.
    public static func fitting(_ ideal: Double, roomBelow: Double) -> Double {
        max(minimum, min(ideal, roomBelow))
    }

    /// Where a window's top has to be for a sheet of this height to fit below it, with its
    /// buttons on screen. The window moves up only as far as that needs, never down, and never
    /// past the top of the screen: a sheet taller than the screen then scrolls.
    /// - Parameter chrome: The window's title bar and a margin, above the sheet.
    public static func raisedTop(
        windowTop: Double, sheetHeight: Double, chrome: Double, visibleBottom: Double, visibleTop: Double
    ) -> Double {
        let needed = visibleBottom + sheetHeight + chrome
        return min(max(windowTop, needed), max(windowTop, visibleTop))
    }
}
