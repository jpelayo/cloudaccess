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
