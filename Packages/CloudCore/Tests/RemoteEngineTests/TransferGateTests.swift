// Apache 2 license - developer@infinitecontext.com

import CloudCore
import Foundation
import Testing

@testable import RemoteEngine

@Suite struct TransferGateTests {
    private func waitUntil(_ gate: TransferGate, queued count: Int) async {
        for _ in 0..<200 where await gate.queued != count {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func aCancelledWaiterLeavesAtOnce() async throws {
        let gate = TransferGate(limit: 1)
        try await gate.acquire()
        let waiter = Task { try await gate.acquire() }
        await waitUntil(gate, queued: 1)

        waiter.cancel()

        await #expect(throws: RemoteError.cancelled) { try await waiter.value }
        #expect(await gate.queued == 0)
    }

    @Test func aCancelledWaiterDoesntCostASlot() async throws {
        let gate = TransferGate(limit: 1)
        try await gate.acquire()
        let cancelled = Task { try await gate.acquire() }
        await waitUntil(gate, queued: 1)
        cancelled.cancel()
        _ = try? await cancelled.value

        await gate.release()

        // The slot came back, so this doesn't wait.
        try await gate.acquire()
    }

    @Test func releasingWakesTheNextInLine() async throws {
        let gate = TransferGate(limit: 1)
        try await gate.acquire()
        let waiter = Task { try await gate.acquire() }
        await waitUntil(gate, queued: 1)

        await gate.release()

        try await waiter.value
        #expect(await gate.queued == 0)
    }
}
