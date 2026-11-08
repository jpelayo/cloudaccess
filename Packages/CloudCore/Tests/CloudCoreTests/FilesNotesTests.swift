// Apache 2 license - developer@infinitecontext.com

import CloudCore
import Foundation
import Testing

/// What the Files extension leaves for the app to show. A change another app saved into a
/// read-only drive exists only on the iPhone, so a person has to be able to see it.
@Suite struct FilesNotesTests {
    private func url() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("FilesNotesTests-\(UUID().uuidString)")
            .appendingPathComponent("drive.json")
    }

    @Test func aKeptChangeComesBackForTheApp() {
        let notes = url()
        FilesNotes.update(at: notes) { $0.keep(id: "item", name: "Report.docx", isNew: false) }
        let read = FilesNotes.read(from: notes)
        #expect(read.kept.map(\.name) == ["Report.docx"])
        #expect(!read.kept[0].explanation.isEmpty)
    }

    /// Saving the same file twice is one thing to know about, not two.
    @Test func aChangeIsListedOnce() {
        let notes = url()
        FilesNotes.update(at: notes) { $0.keep(id: "item", name: "Report.docx", isNew: false) }
        FilesNotes.update(at: notes) { $0.keep(id: "item", name: "Report.docx", isNew: false) }
        #expect(FilesNotes.read(from: notes).kept.count == 1)
    }

    /// Lock and temporary files from a save would bury what matters.
    @Test func scratchFilesArentListed() {
        for name in ["~$Report.docx", ".~lock.Report.odt#", ".sb-1a2b-Report", "~WRL0001.tmp", "._Report.docx", "Save.TMP"] {
            #expect(FilesNotes.isScratch(name), "\(name)")
        }
        #expect(!FilesNotes.isScratch("Report.docx"))
        let notes = url()
        FilesNotes.update(at: notes) { $0.keep(id: "lock", name: "~$Report.docx", isNew: true) }
        #expect(FilesNotes.read(from: notes).kept.isEmpty)
    }

    /// Once the server's file is back, or the person deleted the copy, there's nothing to say,
    /// and the file goes.
    @Test func forgettingTheLastNoteRemovesTheFile() {
        let notes = url()
        FilesNotes.update(at: notes) { $0.keep(id: "item", name: "Report.docx", isNew: false) }
        FilesNotes.update(at: notes) { $0.forget(id: "item") }
        #expect(FilesNotes.read(from: notes).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: notes.path))
    }

    @Test func aProblemIsKeptBesideTheChanges() {
        let notes = url()
        FilesNotes.update(at: notes) { $0.problem = .signIn }
        FilesNotes.update(at: notes) { $0.keep(id: "item", name: "Report.docx", isNew: true) }
        let read = FilesNotes.read(from: notes)
        #expect(read.problem == .signIn)
        #expect(read.kept.count == 1)
        FilesNotes.update(at: notes) { $0.problem = nil }
        #expect(FilesNotes.read(from: notes).problem == nil)
    }

    /// A sign-in problem shows until something works again. No network says nothing, because it
    /// clears by itself.
    @Test func onlyWhatAPersonCanFixIsNoted() {
        #expect(FilesNotes.problem(after: nil) == .some(nil))
        #expect(FilesNotes.problem(after: RemoteError.unauthorized) == .some(.signIn))
        #expect(FilesNotes.problem(after: RemoteError.hostKeyChanged) == .some(.signIn))
        #expect(FilesNotes.problem(after: RemoteError.vault(.wrongPassword)) == .some(.signIn))
        #expect(FilesNotes.problem(after: DriveStore.StoreError.keychain(-25300)) == .some(.passwordUnreadable))
        #expect(FilesNotes.problem(after: RemoteError.unreachable("offline")) == .none)
        // An extension missing the Keychain group never reads the password, until the build is fixed.
        #expect(FilesNotes.problem(after: DriveStore.StoreError.keychain(-34018)) == .some(.passwordUnreadable))
        // Locked since it started: that clears once the iPhone is unlocked.
        #expect(FilesNotes.problem(after: DriveStore.StoreError.keychain(-25308)) == .none)
    }

    /// Try Again is offered only where trying again can help: after a refused sign-in, which the
    /// server may accept later. Not for a password Files can't read, nor for changes kept here.
    @Test func tryingAgainIsOfferedOnlyWhereItCanHelp() {
        #expect(FilesNotes.Problem.signIn.canTryAgain)
        #expect(!FilesNotes.Problem.passwordUnreadable.canTryAgain)
        var kept = FilesNotes()
        kept.keep(id: "1", name: "Report.pdf", isNew: true)
        let cantHelp = [FilesNotes(problem: .passwordUnreadable), kept, FilesNotes()]
        #expect(!FilesNotes.canTryAgain(cantHelp))
        #expect(FilesNotes.canTryAgain(cantHelp + [FilesNotes(problem: .signIn)]))
    }

    /// Notes that can't be read say nothing, rather than stopping the app.
    @Test func unreadableNotesAreEmpty() throws {
        let notes = url()
        try FileManager.default.createDirectory(at: notes.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: notes)
        #expect(FilesNotes.read(from: notes).isEmpty)
    }
}
