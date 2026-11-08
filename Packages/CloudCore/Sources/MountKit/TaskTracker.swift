// Apache 2 license - developer@infinitecontext.com

import Foundation

/// Tasks that must stop when macOS is finished with whatever started them.
public final class TaskTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var isInvalidated = false

    public init() {}

    /// How many tasks are still tracked, which is none once they've all finished.
    public var count: Int {
        lock.withLock { tasks.count }
    }

    /// Runs work as a tracked task, and returns it so a `Progress` can cancel it. The task is
    /// registered under the lock it needs in order to finish, so a task that ends at once can't
    /// finish first and be left tracked forever.
    @discardableResult
    public func run(_ work: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        lock.withLock {
            let id = UUID()
            let task = Task { [weak self] in
                await work()
                self?.finished(id)
            }
            if isInvalidated {
                task.cancel()
            }
            tasks[id] = task
            return task
        }
    }

    private func finished(_ id: UUID) {
        lock.withLock { tasks[id] = nil }
    }

    /// Cancels everything running, and anything started afterwards.
    public func invalidate() {
        let running = lock.withLock {
            isInvalidated = true
            return tasks.values
        }
        for task in running {
            task.cancel()
        }
    }
}
