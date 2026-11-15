// Apache 2 license - developer@infinitecontext.com

import Foundation

/// The downloads that need the screen on. Each one holds its own ID rather than adding to a count,
/// so a download that ends twice can't let go of another one's hold.
public struct AwakeHolds: Sendable {
    private var held: Set<UUID> = []

    public init() {}

    public var isHeld: Bool { !held.isEmpty }

    public mutating func hold() -> UUID {
        let id = UUID()
        held.insert(id)
        return id
    }

    public mutating func release(_ id: UUID) {
        held.remove(id)
    }
}
