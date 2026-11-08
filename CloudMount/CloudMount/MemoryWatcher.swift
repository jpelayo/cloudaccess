// Apache 2 license - developer@infinitecontext.com

import Foundation

/// Listens for macOS running short of memory. A process that gives memory back when asked is
/// a late target when macOS has to end processes to recover.
@MainActor
final class MemoryWatcher {
    enum Level {
        case normal
        case warning
        case critical
    }

    private(set) var level = Level.normal
    private let onChange: @MainActor (Level) -> Void
    private let source = DispatchSource.makeMemoryPressureSource(
        eventMask: [.normal, .warning, .critical], queue: .main)

    /// - Parameter onChange: Called on the main actor each time the level changes.
    init(onChange: @escaping @MainActor (Level) -> Void) {
        self.onChange = onChange
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let event = self.source.data
                if event.contains(.critical) {
                    self.change(to: .critical)
                } else if event.contains(.warning) {
                    self.change(to: .warning)
                } else {
                    self.change(to: .normal)
                }
            }
        }
        source.activate()
    }

    deinit {
        source.cancel()
    }

    private func change(to newLevel: Level) {
        level = newLevel
        onChange(newLevel)
    }

    #if DEBUG
    /// Tests the response in this app alone, without pressuring the whole system.
    func simulate(_ newLevel: Level) {
        change(to: newLevel)
    }
    #endif
}
