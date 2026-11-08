// Apache 2 license - developer@infinitecontext.com

import Foundation

/// The time ran out before an answer came.
public struct TimedOut: Error, Equatable {
    public init() {}
}

/// Waits for an answer, but not forever. File Provider calls have no limit of their own and can't
/// be cancelled, and polls run one at a time, so one call that never came back would stop every
/// drive from being checked. If the time runs out the work carries on, and its answer is dropped.
public func withinTime<Value: Sendable>(
    _ limit: Duration,
    _ work: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    let answer = FirstAnswer<Value>()
    return try await withCheckedThrowingContinuation { continuation in
        answer.wait(with: continuation)
        let timer = Task {
            try await Task.sleep(for: limit)
            answer.give(.failure(TimedOut()))
        }
        Task {
            defer { timer.cancel() }
            do {
                answer.give(.success(try await work()))
            } catch {
                answer.give(.failure(error))
            }
        }
    }
}

/// Resumes a continuation exactly once, whichever side gets there first.
private final class FirstAnswer<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    func wait(with continuation: CheckedContinuation<Value, Error>) {
        lock.withLock { self.continuation = continuation }
    }

    func give(_ result: Result<Value, Error>) {
        let waiting = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        waiting?.resume(with: result)
    }
}
