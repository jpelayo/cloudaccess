// Apache 2 license - developer@infinitecontext.com

import Foundation
import Network

/// Reports when the device's network comes and goes, which is far sooner than a request timing
/// out. It only knows about this device: a server can still be down with the network up.
public final class NetworkWatcher: Sendable {
    private let monitor = NWPathMonitor()

    /// - Parameter onChange: Called with whether a network is available, once at the start and
    ///   then on each change, on a background queue.
    public init(onChange: @escaping @Sendable (Bool) -> Void) {
        monitor.pathUpdateHandler = { path in
            onChange(path.status == .satisfied)
        }
        monitor.start(queue: DispatchQueue(label: "cloudaccess.network"))
    }

    deinit {
        monitor.cancel()
    }
}
