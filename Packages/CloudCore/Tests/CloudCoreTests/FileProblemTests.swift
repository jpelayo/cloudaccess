// Apache 2 license - developer@infinitecontext.com

import CloudCore
import Foundation
import Testing

@Suite struct FileProblemTests {
    private let path = RemotePath("/comparativa.numbers")!

    /// "Failed once" tells nobody anything, so every failure has to say why and what to do.
    @Test func everyFileFailureSaysWhyAndWhatToDo() {
        let failures: [RemoteError] = [
            .notFound(path), .alreadyExists(path), .parentMissing(path), .forbidden(path), .locked(path),
            .nameTooLong(path), .reservedName(".cloudmount"), .notAPlainFile(path, .package),
            .notAPlainFile(path, .folder), .notAPlainFile(path, .link), .notAPlainFile(path, .other),
            .unreadableHere(path, "is a directory"), .readOnly, .failed(path, "No"), .tooSlow(path),
            .unreachable("connection reset by peer"), .server(status: 500), .insufficientStorage,
            .tooLarge(path), .server(status: RemoteError.tooManyRequests), .tooManyItems(path),
        ]
        for failure in failures {
            #expect(!failure.problem.cause.isEmpty, "\(failure)")
            #expect(!failure.problem.fix.isEmpty, "\(failure)")
        }
    }

    @Test func aProblemSurvivesBeingStored() {
        let problem = FileProblem(cause: "Why.", fix: "What to do.")
        #expect(FileProblem(stored: problem.stored) == problem)
    }

    /// Rows from before this existed hold a single line.
    @Test func anOlderReasonStillReads() {
        let problem = FileProblem(stored: "The server refused.")
        #expect(problem.cause == "The server refused.")
        #expect(problem.fix.isEmpty)
    }

    /// The engine's text can be a long request with an address in it, and only the end helps.
    @Test func aBrokenConnectionKeepsOnlyWhatHelps() {
        let error = RemoteError.unreachable(#"Put "https://example.invalid/a": read tcp: connection reset by peer"#)
        #expect(error.problem.cause.contains("(connection reset by peer)"))
        #expect(!error.problem.cause.contains("https"))
    }

    /// A folder too big for the Files extension is refused whole. Showing what's known keeps
    /// the system from taking a short listing to mean the rest was deleted.
    @Test func aFolderTooBigForFilesLeavesItsListingAlone() {
        #expect(RemoteError.tooManyItems(path).leavesListingAlone)
        #expect(RemoteError.tooManyItems(path).scope == .item)
        #expect(!RemoteError.tooManyItems(path).canHoldAFile)
    }

    /// A person has to see these, and a file on the server can reach them through a rename.
    @Test func whatCantBeSentCanBeHeld() {
        #expect(RemoteError.notAPlainFile(path, .folder).canHoldAFile)
        #expect(RemoteError.nameTooLong(path).canHoldAFile)
        #expect(RemoteError.reservedName(".cloudmount").canHoldAFile)
        #expect(RemoteError.notAPlainFile(path, .link).scope == .item)
        #expect(RemoteError.unreadableHere(path, "No").scope == .item)
    }
}
