// Apache 2 license - developer@infinitecontext.com

import FileProvider
import FileProviderShell
import Foundation
import MountKit
import SyncCore
import Testing

/// What macOS and iOS are shown from a file's details.
@Suite struct FileDetailsShellTests {
    private let modified = Date(timeIntervalSince1970: 1_551_694_530)
    private let created = Date(timeIntervalSince1970: 1_543_651_200)

    /// The file's own dates, when its details give them. An item without details keeps the
    /// metadata version it had before details existed, so nothing is listed again for nothing, and
    /// the content version never moves, so nothing downloads again.
    @Test func macOSIsShownTheFilesOwnDates() {
        let item = SyncItem(
            id: "1", parentID: SyncItem.rootID, name: "report.txt", kind: .file, size: 5, modified: modified,
            version: "v", versionID: "\"1\"", generation: 0)
        var described = item
        described.ownModified = created
        described.created = created
        let shown = FileProviderItem(described, isReadOnly: false)
        #expect(shown.contentModificationDate == created)
        #expect(shown.creationDate == created)
        let plain = FileProviderItem(item, isReadOnly: false)
        #expect(plain.contentModificationDate == modified)
        #expect(plain.creationDate == nil)
        #expect(ItemVersions.content(of: described) == ItemVersions.content(of: item))
        #expect(ItemVersions.metadata(of: described) != ItemVersions.metadata(of: item))
    }
}
