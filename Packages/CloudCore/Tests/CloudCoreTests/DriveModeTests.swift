// Apache 2 license - developer@infinitecontext.com

import CloudCore
import Foundation
import Testing

/// A drive's mode: Safe keeps the `.cloudmount` folder, Unsafe writes only a person's files and
/// is for SFTP only, and Read-only writes nothing.
@Suite struct DriveModeTests {
    private func settings(_ json: String) throws -> DriveSettings {
        try JSONDecoder().decode(DriveSettings.self, from: Data(json.utf8))
    }

    private func drive(_ endpoint: Connection.Endpoint, mode: DriveMode) -> Connection {
        var connection = Connection(displayName: "Work", endpoint: endpoint, rootPath: "/cloudmount-test")
        connection.settings.mode = mode
        return connection
    }

    private let sftp = Connection.Endpoint.sftp(host: "files.example.com", port: 22)
    private let webDAV = Connection.Endpoint.webDAV(url: URL(string: "https://files.example.com/cloudmount-test")!)

    @Test func aDriveSavedBeforeModesKeepsItsReadOnlyChoice() throws {
        #expect(try settings(#"{"isReadOnly": true}"#).mode == .readOnly)
        #expect(try settings(#"{"isReadOnly": false}"#).mode == .safe)
        #expect(try settings("{}").mode == .safe)
    }

    @Test func aModeFromANewerBuildWritesNothing() throws {
        #expect(try settings(#"{"mode": "unsafe"}"#).mode == .unsafe)
        #expect(try settings(#"{"mode": "somethingNew"}"#).mode == .readOnly)
    }

    /// A build from before modes only reads `isReadOnly`, so a Read-only drive must stay read-only
    /// there too.
    @Test func anOlderBuildStillSeesAReadOnlyDrive() throws {
        for mode in DriveMode.allCases {
            var saved = DriveSettings()
            saved.mode = mode
            let data = try JSONEncoder().encode(saved)
            let fields = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(fields["isReadOnly"] as? Bool == (mode == .readOnly))
            #expect(try JSONDecoder().decode(DriveSettings.self, from: data) == saved)
        }
    }

    @Test func switchingReadOnlyOffLeavesAnUnsafeDriveUnsafe() {
        var settings = DriveSettings()
        settings.mode = .unsafe
        settings.isReadOnly = false
        #expect(settings.mode == .unsafe)
        settings.isReadOnly = true
        #expect(settings.mode == .readOnly)
        settings.isReadOnly = false
        #expect(settings.mode == .safe)
    }

    @Test func unsafeIsOnlyOfferedForSFTP() {
        #expect(DriveMode.available(for: sftp) == [.safe, .unsafe, .readOnly])
        #expect(DriveMode.available(for: webDAV) == [.safe, .readOnly])
    }

    /// WebDAV servers remove the old file before moving a new one in, so an Unsafe save there
    /// could lose it. Falling back to Safe quietly would write the folder a person chose to avoid.
    @Test func aWebDAVDriveIsNeverSavedInUnsafeMode() {
        #expect(DriveEdit.modeRefusal(for: drive(webDAV, mode: .unsafe)) != nil)
        #expect(DriveEdit.modeRefusal(for: drive(webDAV, mode: .readOnly)) == nil)
        #expect(DriveEdit.modeRefusal(for: drive(sftp, mode: .unsafe)) == nil)
    }

    @Test func onlySafeModeUsesTheTrashAndSharedSettings() {
        #expect(drive(sftp, mode: .safe).writesControlFolder)
        #expect(!drive(sftp, mode: .unsafe).writesControlFolder)
        #expect(!drive(sftp, mode: .readOnly).writesControlFolder)
        var limited = drive(sftp, mode: .safe)
        limited.serverIsReadOnly = true
        #expect(!limited.writesControlFolder)
    }

    @Test func everyModeSaysWhatItGivesUp() {
        for mode in DriveMode.allCases {
            #expect(!mode.title.isEmpty)
            #expect(!mode.explanation.isEmpty)
        }
        #expect(DriveMode.unsafe.explanation.hasPrefix("Attention"))
    }
}
