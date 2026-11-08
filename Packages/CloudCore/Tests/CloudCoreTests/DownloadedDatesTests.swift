// Apache 2 license - developer@infinitecontext.com

import CloudCore
import Foundation
import Testing

/// A copy downloaded to the iPhone keeps the file's own dates, so sharing it or saving it to Files
/// doesn't make it look new.
@Suite struct DownloadedDatesTests {
    private func downloaded() throws -> URL {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("bytes".utf8).write(to: file)
        return file
    }

    @Test func aCopyTakesTheFilesOwnDates() throws {
        let file = try downloaded()
        defer { try? FileManager.default.removeItem(at: file) }
        let modified = Date(timeIntervalSince1970: 1_551_694_530)
        let created = Date(timeIntervalSince1970: 1_543_651_200)
        let item = RemoteItem(
            path: RemotePath("/report.txt")!, kind: .file, size: 5, modified: Date(),
            ownModified: modified, created: created)
        OfflineLibrary.stamp(file, with: item)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect(attributes[.modificationDate] as? Date == modified)
        #expect(attributes[.creationDate] as? Date == created)
    }

    /// Without details there's no date of the file's own to give, and the server's is only when it
    /// arrived there, so the copy keeps its own.
    @Test func withoutDetailsTheCopyKeepsItsOwnDates() throws {
        let file = try downloaded()
        defer { try? FileManager.default.removeItem(at: file) }
        let before = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        let item = RemoteItem(
            path: RemotePath("/report.txt")!, kind: .file, size: 5, modified: Date(timeIntervalSince1970: 0))
        OfflineLibrary.stamp(file, with: item)
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date == before)
    }
}
