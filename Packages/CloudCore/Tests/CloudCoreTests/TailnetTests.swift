// Apache 2 license - developer@infinitecontext.com

import Foundation
import Testing
@testable import CloudCore

@Suite struct TailnetTests {
    @Test(arguments: [
        "100.64.0.1", "100.100.100.100", "100.127.255.254",
        "nas.tail1234.ts.net", "NAS.TAIL1234.TS.NET", "nas.tail1234.ts.net.",
        "fd7a:115c:a1e0::1", "FD7A:115C:A1E0:AB12::1",
    ])
    func tailscaleAddressesAreRecognised(host: String) {
        #expect(Tailnet.contains(host: host))
    }

    @Test(arguments: [
        "100.63.255.255", "100.128.0.1", "10.0.0.1", "192.168.1.10", "127.0.0.1",
        "example.com", "ts.net.example.com", "notts.net", "100.64.0", "100.64.0.1.example.com",
        "100.64.0.300", "fd7a:115c:a1e1::1", "",
    ])
    func otherAddressesAreNot(host: String) {
        #expect(!Tailnet.contains(host: host))
    }

    @Test func aDriveKnowsWhetherItNeedsTailscale() throws {
        let url = try #require(URL(string: "https://nas.tail1234.ts.net/cloudmount-test"))
        #expect(Connection(displayName: "A", endpoint: .webDAV(url: url)).usesTailnet)
        #expect(Connection(displayName: "B", endpoint: .sftp(host: "100.101.102.103", port: 22)).usesTailnet)
        #expect(!Connection(displayName: "C", endpoint: .sftp(host: "example.com", port: 22)).usesTailnet)
        #expect(!Connection(displayName: "D", endpoint: .localFolder).usesTailnet)
    }

    @Test func anUnreachableTailnetServerSaysWhatToCheck() {
        let message = Tailnet.explain(RemoteError.unreachable("No route to host."), for: .sftp(host: "100.64.0.1", port: 22))
        #expect(message.contains("can't be reached"))
        #expect(message.contains("Tailscale"))
    }

    @Test func aWrongPasswordIsntBlamedOnTailscale() {
        let message = Tailnet.explain(RemoteError.unauthorized, for: .sftp(host: "100.64.0.1", port: 22))
        #expect(!message.contains("Tailscale"))
    }

    @Test func anOrdinaryServerDoesntMentionTailscale() {
        let message = Tailnet.explain(RemoteError.unreachable("No route to host."), for: .sftp(host: "example.com", port: 22))
        #expect(!message.contains("Tailscale"))
    }
}
