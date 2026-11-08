// Apache 2 license - developer@infinitecontext.com

import Foundation
import Testing
@testable import CloudCore

@Suite struct PanelHeightTests {
    @Test func aPanelStopsAtHalfTheScreen() {
        #expect(PanelHeight.limit(screenHeight: 900) == 450)
    }

    @Test func aShortListTakesItsNaturalHeight() {
        #expect(PanelHeight.list(rows: 3, rowHeight: 42, chrome: 34, available: 400) == 160)
    }

    @Test func aThousandRowsKeepToTheSpaceLeft() {
        let height = PanelHeight.list(rows: 1000, rowHeight: 42, chrome: 34, available: 400)
        #expect(height == 34 + 8 * 42)
        #expect(height <= 400)
    }

    @Test func aListShowsWholeRows() {
        let height = PanelHeight.list(rows: 20, rowHeight: 42, chrome: 34, available: 100)
        #expect((height - 34).truncatingRemainder(dividingBy: 42) == 0)
    }

    @Test func withNoRoomLeftOneRowStillShows() {
        #expect(PanelHeight.list(rows: 40, rowHeight: 42, chrome: 34, available: 0) == 76)
        #expect(PanelHeight.list(rows: 40, rowHeight: 42, chrome: 34, available: -50) == 76)
    }

    @Test func anEmptyListIsJustItsChrome() {
        #expect(PanelHeight.list(rows: 0, rowHeight: 42, chrome: 34, available: 400) == 34)
    }
}

@Suite struct DriveDetailsTests {
    @Test func aDriveSaysWhereItIsAndWhatKindItIs() throws {
        let url = try #require(URL(string: "https://example.com/cloudmount-test"))
        var connection = Connection(
            displayName: "Work", endpoint: .webDAV(url: url), username: "someone", isEncrypted: true)
        connection.settings.isReadOnly = true
        #expect(ConnectionSummary.details(of: connection) == [
            .init(key: "Address", value: "https://example.com/cloudmount-test"),
            .init(key: "User", value: "someone"),
            .init(key: "Kind", value: "WebDAV, encrypted, read-only"),
        ])
    }

    @Test func aDriveWithNoUserLeavesThatLineOut() {
        let connection = Connection(
            displayName: "Work", endpoint: .sftp(host: "example.com", port: 23), rootPath: "/data")
        #expect(ConnectionSummary.details(of: connection) == [
            .init(key: "Address", value: "sftp://example.com:23/data"),
            .init(key: "Kind", value: "SFTP, plain"),
        ])
    }
}
