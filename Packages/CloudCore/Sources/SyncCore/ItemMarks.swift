// Apache 2 license - developer@infinitecontext.com

import Foundation

/// What a person set on an item on this device: when they last used it, its tags, and its place
/// among their favourites. Apple asks a provider to keep these and hand them back, and says they
/// must not be shared between people, so they never go to the server. The system's Recents, tag
/// lists and favourites sidebar are built from them.
public struct ItemMarks: Equatable, Sendable {
    public var lastUsed: Date?
    /// The system's own encoding of the tags, kept exactly as it was given.
    public var tags: Data?
    /// Where the item sits among favourites. The system's "unranked" value is kept as given too.
    public var favoriteRank: Int64?

    public init(lastUsed: Date? = nil, tags: Data? = nil, favoriteRank: Int64? = nil) {
        self.lastUsed = lastUsed
        self.tags = tags
        self.favoriteRank = favoriteRank
    }

    public var isEmpty: Bool {
        lastUsed == nil && tags == nil && favoriteRank == nil
    }

    /// These marks with the system's changes applied. A field the system didn't send stays as it
    /// was; one it sent as nothing is cleared, because that's how a tag or favourite is removed.
    public func applying(
        lastUsed newLastUsed: Date?? = .none, tags newTags: Data?? = .none,
        favoriteRank newRank: Int64?? = .none
    ) -> ItemMarks {
        var updated = self
        if case .some(let value) = newLastUsed {
            // A date only moves forward: an older one arriving late mustn't push a file down Recents.
            updated.lastUsed = [lastUsed, value].compactMap { $0 }.max()
        }
        if case .some(let value) = newTags {
            updated.tags = value
        }
        if case .some(let value) = newRank {
            updated.favoriteRank = value
        }
        return updated
    }
}
