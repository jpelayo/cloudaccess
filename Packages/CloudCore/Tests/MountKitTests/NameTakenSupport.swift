// Apache 2 license - developer@infinitecontext.com

import MountKit
import Testing

private struct NothingWasTaken: Error {}

/// Runs something that has to fail because a name is taken, and returns what it said, so a test
/// can check which item macOS is told has the name.
func nameTaken(
    sourceLocation: SourceLocation = #_sourceLocation, _ body: () async throws -> Void
) async throws -> NameTaken {
    do {
        try await body()
    } catch let taken as NameTaken {
        return taken
    }
    Issue.record("Nothing said the name was taken", sourceLocation: sourceLocation)
    throw NothingWasTaken()
}
