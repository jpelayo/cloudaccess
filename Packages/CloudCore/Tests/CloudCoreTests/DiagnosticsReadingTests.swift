// Apache 2 license - developer@infinitecontext.com

import CloudCore
import Foundation
import Testing

/// What the log says about a failure, and what a person reads back on the iPhone. A release build
/// keeps no file names, so a failure has to be told by its kind alone.
@Suite struct DiagnosticsReadingTests {
    private let path = RemotePath("/Privado/Vacaciones.mov")!

    // MARK: Kinds

    @Test func aFailureNeverCarriesItsFileName() {
        let kind = Diagnostics.kind(of: RemoteError.failed(path, "The server didn't send all of Vacaciones.mov."))
        #expect(kind == "failed")
        #expect(Diagnostics.kind(of: RemoteError.notFound(path)) == "notFound")
        #expect(Diagnostics.kind(of: RemoteError.tooSlow(path)) == "tooSlow")
    }

    @Test func whatHelpsIsKept() {
        #expect(Diagnostics.kind(of: RemoteError.vault(.wrongPassword)) == "vault wrongPassword")
        #expect(Diagnostics.kind(of: RemoteError.vault(.malformed)) == "vault malformed")
        #expect(Diagnostics.kind(of: RemoteError.server(status: 503)) == "server 503")
        #expect(Diagnostics.kind(of: RemoteError.unreachable("dial tcp 10.0.0.1:443: i/o timeout")) == "unreachable (timeout)")
        #expect(Diagnostics.kind(of: RemoteError.unreachable("something odd at /Privado")) == "unreachable (other)")
        #expect(Diagnostics.kind(of: DriveStore.StoreError.keychain(-34018)) == "keychain -34018")
    }

    @Test func aPlainCaseIsNamed() {
        #expect(Diagnostics.kind(of: RemoteError.unauthorized) == "unauthorized")
        #expect(Diagnostics.kind(of: RemoteError.readOnly) == "readOnly")
        #expect(Diagnostics.kind(of: CancellationError()) == "cancelled")
        #expect(Diagnostics.kind(of: URLError(.timedOut)) == "NSURLErrorDomain -1001")
    }

    // MARK: Reading back

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiagnosticsReadingTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func age(_ log: Diagnostics, day: Date, by days: Double) throws {
        let file = log.folder.appendingPathComponent("diagnostics-\(day.ISO8601Format().prefix(10)).log")
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-days * 86_400)], ofItemAtPath: file.path)
    }

    @Test func theLatestLinesComeFromEveryDayKept() throws {
        let log = Diagnostics(directory: try temporaryFolder())
        let yesterday = Date().addingTimeInterval(-86_400)
        log.record("one", now: yesterday)
        log.record("two", now: yesterday)
        try age(log, day: yesterday, by: 1)
        log.record("three")

        let words = { (lines: [String]) in lines.map { String($0.split(separator: " ").last ?? "") } }
        #expect(words(log.recentLines(limit: 10)) == ["one", "two", "three"])
        #expect(words(log.recentLines(limit: 2)) == ["two", "three"])
    }

    @Test func anEmptyLogHasNoLines() throws {
        #expect(Diagnostics(directory: try temporaryFolder()).recentLines(limit: 10).isEmpty)
    }
}
