// Apache 2 license - developer@infinitecontext.com

import SwiftUI

@main
struct CloudWanderApp: App {
    init() {
        AppLog.start()
    }

    var body: some Scene {
        WindowGroup {
            DrivesView()
        }
    }
}
