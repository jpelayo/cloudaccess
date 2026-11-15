// Apache 2 license - developer@infinitecontext.com

@testable import CloudCore
import Testing

@Suite struct CreditsTests {
    private let known: Set<String> = [
        "MIT", "BSD-2-Clause", "BSD-3-Clause", "Apache-2.0", "ISC", "MPL-2.0", "LGPL-2.1", "CC0-1.0", "Unlicense",
    ]

    private func credit(_ name: String) -> Credit? {
        Credits.all.first { $0.name == name }
    }

    @Test func everyEntryIsComplete() {
        #expect(Credits.all.count > 10)
        for credit in Credits.all {
            #expect(!credit.name.isEmpty)
            #expect(!credit.version.isEmpty, "\(credit.name)")
            #expect(!credit.text.isEmpty, "\(credit.name)")
            #expect(!credit.platforms.isEmpty, "\(credit.name)")
            for licence in credit.licence.split(separator: ", ") {
                #expect(known.contains(String(licence)), "\(credit.name): \(licence)")
            }
        }
    }

    @Test func theEngineAndGoAreOnBothApps() {
        for name in ["github.com/rclone/rclone", "github.com/pkg/sftp", "golang.org/x/crypto", "Go"] {
            #expect(credit(name)?.platforms == ["iOS", "macOS"], "\(name)")
        }
        #expect(credit("github.com/rclone/rclone")?.licence == "MIT")
    }

    @Test func vlcKitIsOnTheIPhoneOnly() {
        #expect(credit("VLCKit")?.platforms == ["iOS"])
        #expect(credit("VLCKit")?.licence == "LGPL-2.1")
    }

    @Test func thisAppSeesOnlyItsOwn() {
        #expect(Credits.forThisApp.allSatisfy { $0.platforms.contains(Credits.thisPlatform) })
        // Tests run on the Mac.
        #expect(!Credits.forThisApp.contains { $0.name == "VLCKit" })
    }
}
