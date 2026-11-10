// Apache 2 license - developer@infinitecontext.com

import CloudCore
import Foundation
import Testing

@Suite struct InterruptedReplacementTests {
    /// A reset or a move saves the new drive before the old one goes. Whatever point a crash
    /// reaches, repair must end with the new drive, and so with its passwords.
    @Test func aCrashBeforeTheOldDriveWentFinishesBoth() {
        let old = UUID()
        let new = UUID()
        let actions = DriveRepair.plan(
            drives: [(old, .removing), (new, .active)], domains: [old.uuidString])
        #expect(actions.contains(.finishRemoving(old)))
        #expect(actions.contains(.register(new)))
        #expect(!actions.contains(.forget(new)))
    }

    @Test func aCrashAfterTheOldDriveWentRegistersTheNewOne() {
        let new = UUID()
        #expect(DriveRepair.plan(drives: [(new, .active)], domains: []) == [.register(new)])
    }
}

@Suite struct ErrorMeaningTests {
    private let path = RemotePath("/folder")!

    @Test func aSlowFolderIsNeverAnOutage() {
        #expect(RemoteError.tooSlow(path).scope == .item)
        #expect(RemoteError.tooSlow(path).isRetryable)
        #expect(RemoteError.tooSlow(path).leavesListingAlone)
    }

    @Test func onlyWhatPeopleMustFixAsksForThem() {
        #expect(RemoteError.unreachable("gone").attentionLabel == nil)
        #expect(RemoteError.server(status: 503).attentionLabel == nil)
        #expect(RemoteError.unauthorized.attentionLabel != nil)
        #expect(RemoteError.vault(.retired).attentionLabel != nil)
        #expect(RemoteError.vault(.wrongPassword).attentionLabel != nil)
    }

    @Test func aFullServerBelongsOnTheFile() {
        #expect(RemoteError.insufficientStorage.belongsOnAFile)
        #expect(RemoteError.forbidden(path).belongsOnAFile)
        #expect(!RemoteError.unreachable("gone").belongsOnAFile)
        #expect(!RemoteError.cancelled.belongsOnAFile)
        #expect(!RemoteError.versionMismatch(path).belongsOnAFile)
    }
}

@Suite struct KeptDownloadTests {
    private let drive = UUID()
    private let path = RemotePath("/report.pdf")!

    private func library() throws -> OfflineLibrary {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return OfflineLibrary(directory: folder)
    }

    private func keep(_ library: OfflineLibrary, version: String?) throws {
        let incoming = try library.temporaryFile(drive: drive)
        try Data("bytes".utf8).write(to: incoming)
        try library.keep(incoming, as: path, drive: drive, version: version)
    }

    /// An export of old bytes under a row showing the new size is the mistake this prevents.
    @Test func aNewerVersionOnTheServerIsNoticed() throws {
        let library = try library()
        try keep(library, version: "one")
        #expect(!library.isOutdated(path, drive: drive, serverVersion: "one"))
        #expect(library.isOutdated(path, drive: drive, serverVersion: "two"))
    }

    @Test func aNewDownloadIsCurrentAgain() throws {
        let library = try library()
        try keep(library, version: "one")
        try keep(library, version: "two")
        #expect(!library.isOutdated(path, drive: drive, serverVersion: "two"))
    }

    @Test func aFileWithNoVersionOnRecordCountsAsOlder() throws {
        let library = try library()
        try keep(library, version: nil)
        #expect(library.isOutdated(path, drive: drive, serverVersion: "one"))
    }

    @Test func nothingKeptIsNeverOutdated() throws {
        let library = try library()
        #expect(!library.isOutdated(path, drive: drive, serverVersion: "one"))
    }

    @Test func aServerWithNoVersionsSaysNothing() throws {
        let library = try library()
        try keep(library, version: "one")
        #expect(!library.isOutdated(path, drive: drive, serverVersion: nil))
    }

    /// A file can be called anything, including what the record is called.
    @Test func aFileNamedVersionIsntConfusedWithTheRecord() throws {
        let library = try library()
        let named = RemotePath("/version")!
        let incoming = try library.temporaryFile(drive: drive)
        try Data("bytes".utf8).write(to: incoming)
        let kept = try library.keep(incoming, as: named, drive: drive, version: "one")
        #expect(try Data(contentsOf: kept) == Data("bytes".utf8))
    }

    /// This may be the only copy within reach, so it stays until the new one is complete.
    @Test func aFailedReplacementKeepsTheOldFile() throws {
        let library = try library()
        try keep(library, version: "one")
        let missing = try library.temporaryFile(drive: drive)

        #expect(throws: (any Error).self) {
            try library.keep(missing, as: path, drive: drive, version: "two")
        }

        let kept = try #require(library.download(of: path, drive: drive))
        #expect(try Data(contentsOf: kept) == Data("bytes".utf8))
        #expect(!library.isOutdated(path, drive: drive, serverVersion: "one"))
    }

    @Test func aReplacementReplaces() throws {
        let library = try library()
        try keep(library, version: "one")
        let incoming = try library.temporaryFile(drive: drive)
        try Data("newer".utf8).write(to: incoming)

        try library.keep(incoming, as: path, drive: drive, version: "two")

        let kept = try #require(library.download(of: path, drive: drive))
        #expect(try Data(contentsOf: kept) == Data("newer".utf8))
    }

    @Test func aKilledDownloadIsClearedAtTheNextStart() throws {
        let library = try library()
        try keep(library, version: "one")
        let abandoned = try library.temporaryFile(drive: drive)
        try Data("partial".utf8).write(to: abandoned)

        library.clearAbandoned()

        #expect(!FileManager.default.fileExists(atPath: abandoned.path))
        #expect(library.download(of: path, drive: drive) != nil)
    }

    @Test func removingADownloadForgetsItsVersion() throws {
        let library = try library()
        try keep(library, version: "one")
        library.removeDownload(of: path, drive: drive)
        try keep(library, version: nil)
        #expect(library.isOutdated(path, drive: drive, serverVersion: "one"))
    }
}


/// A server holds these as two files, so they can't be one path here.
@Suite struct ExactNameTests {
    @Test func twoUnicodeSpellingsAreTwoPaths() {
        let composed = RemotePath("/caf\u{E9}.txt")
        let decomposed = RemotePath("/cafe\u{301}.txt")
        #expect(composed != decomposed)
        #expect(Set([composed, decomposed]).count == 2)
    }

    @Test func theSamePathIsTheSamePath() {
        #expect(RemotePath("/folder/file.txt") == RemotePath("/folder/file.txt"))
        #expect(Set([RemotePath("/a"), RemotePath("/a")]).count == 1)
    }

    @Test func caseStaysDistinct() {
        #expect(RemotePath("/Report.txt") != RemotePath("/report.txt"))
    }
}

@Suite struct RedactionTests {
    @Test func aQuotedPhraseGoesWhole() {
        let cleaned = Diagnostics.redact(#"vaultPassword: "audit alpha beta" done"#)
        #expect(!cleaned.contains("alpha"))
        #expect(!cleaned.contains("beta"))
        #expect(cleaned.contains("done"))
    }

    @Test func aSingleQuotedPhraseGoesWhole() {
        #expect(!Diagnostics.redact("secret='one two three'").contains("two"))
    }

    @Test func anEscapedQuoteDoesntEndTheValue() {
        #expect(!Diagnostics.redact(#"password = "one \" two""#).contains("two"))
    }

    @Test func aQuoteThatNeverClosesGoesToTheEndOfTheLine() {
        let cleaned = Diagnostics.redact("password: \"one two\nnext line")
        #expect(!cleaned.contains("two"))
        #expect(cleaned.contains("next line"))
    }

    @Test func aSignInHeaderGoes() {
        #expect(!Diagnostics.redact("Authorization: Basic c29tZW9uZTpzZWNyZXQ=").contains("c29tZW9uZ"))
        #expect(!Diagnostics.redact("sent bearer abcdefghijklmnop to the server").contains("abcdefgh"))
    }

    @Test func ordinaryWordsStay() {
        #expect(Diagnostics.redact("Basic sign-in failed for the drive") == "Basic sign-in failed for the drive")
    }

    /// The export runs it again, so text written by an older build is covered.
    @Test func whatsExportedIsRedacted() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"old line password: "kept here""#.utf8).write(to: folder.appendingPathComponent("diagnostics.log"))

        #expect(!Diagnostics(directory: folder).exportedText(header: "CloudAccess").contains("kept here"))
    }
}
