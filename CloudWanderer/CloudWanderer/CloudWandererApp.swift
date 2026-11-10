// Apache 2 license - developer@infinitecontext.com

import SwiftUI

@main
struct CloudWandererApp: App {
    init() {
        AppLog.start()
    }

    var body: some Scene {
        WindowGroup {
            DrivesView()
        }
    }
}
