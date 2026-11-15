// Apache 2 license - developer@infinitecontext.com

import CloudCore
import Foundation
import UIKit

/// Keeps the iPhone from locking while a download runs. A locked iPhone suspends the app, and the
/// download with it. Each download releases its hold in a `defer`, so every ending lets go.
@MainActor
enum ScreenAwake {
    private static var holds = AwakeHolds()

    static func hold() -> UUID {
        let id = holds.hold()
        apply()
        return id
    }

    static func release(_ id: UUID) {
        holds.release(id)
        apply()
    }

    private static func apply() {
        UIApplication.shared.isIdleTimerDisabled = holds.isHeld
    }
}
