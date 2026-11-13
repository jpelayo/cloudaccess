// Apache 2 license - developer@infinitecontext.com

import Foundation
import Testing
@testable import CloudCore

/// Only one copy of the Mac app runs, decided by a lock the system takes in one step. Each open
/// of the file is its own holder, even in one process, so two copies can be played here.
@Suite struct InstanceLockTests {
    private func lockFile() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "instance-lock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appending(path: "instance.lock")
    }

    @Test func onlyOneCopyHoldsTheLock() throws {
        let url = try lockFile()
        let first = try #require(InstanceLock.take(url))
        #expect(InstanceLock.take(url) == nil)
        #expect(InstanceLock.isHeld(url))
        first.release()
        #expect(!InstanceLock.isHeld(url))
        #expect(InstanceLock.take(url) != nil)
    }

    /// The system lets go when its holder ends, however it ends. Here the holder just goes away.
    @Test func theLockIsFreeOnceItsHolderGoes() throws {
        let url = try lockFile()
        var holder = InstanceLock.take(url)
        #expect(holder != nil)
        holder = nil
        #expect(!InstanceLock.isHeld(url))
    }

    /// Looking doesn't take it: a copy that only looked leaves it free for the next.
    @Test func lookingLeavesTheLockFree() throws {
        let url = try lockFile()
        #expect(!InstanceLock.isHeld(url))
        #expect(!InstanceLock.isHeld(url))
        #expect(InstanceLock.take(url) != nil)
    }

    @Test func theHolderSaysWhoItIs() throws {
        let url = try lockFile()
        let lock = try #require(InstanceLock.take(url))
        lock.record(InstanceLock.Holder(pid: 4242, isAgent: true))
        #expect(InstanceLock.holder(url) == InstanceLock.Holder(pid: 4242, isAgent: true))
        // A shorter record replaces a longer one whole.
        lock.record(InstanceLock.Holder(pid: 7, isAgent: false))
        #expect(InstanceLock.holder(url) == InstanceLock.Holder(pid: 7, isAgent: false))
        // A holder that ended leaves its record, for the copy that takes over.
        lock.release()
        #expect(InstanceLock.holder(url)?.pid == 7)
    }

    /// The agent's copy waits for the lock, and takes it once the running copy lets go.
    @Test func aWaitingCopyTakesOverWhenTheLockIsFree() async throws {
        let url = try lockFile()
        let running = try #require(InstanceLock.take(url))
        let waiting = Task.detached { InstanceLock.wait(for: url) != nil }
        try await Task.sleep(for: .milliseconds(200))
        #expect(InstanceLock.isHeld(url))
        running.release()
        #expect(await waiting.value)
    }

    /// A second copy waiting to take over finds the first already waiting, and leaves.
    @Test func onlyOneCopyWaits() throws {
        let url = try lockFile().deletingLastPathComponent().appending(path: "standby.lock")
        let waiting = try #require(InstanceLock.takeSoon(url))
        #expect(InstanceLock.isHeld(url))
        #expect(InstanceLock.takeSoon(url) == nil)
        waiting.release()
        #expect(InstanceLock.takeSoon(url) != nil)
    }
}
