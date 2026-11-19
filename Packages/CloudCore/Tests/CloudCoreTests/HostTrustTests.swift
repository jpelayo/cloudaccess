// Apache 2 license - developer@infinitecontext.com

import CloudCore
import Testing

/// A new SFTP server is trusted once, by a person. A key already trusted for the same server, by
/// another drive on this device, isn't asked about again. Anything else is.
@Suite struct HostTrustTests {
    private let key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExample"

    private func drive(host: String = "box.example.com", port: Int = 23, key: String?) -> Connection {
        Connection(
            displayName: "Box", endpoint: .sftp(host: host, port: port), username: "me",
            rootPath: "/home/cloudmount-test", isEncrypted: false, hostKey: key)
    }

    @Test func aKeyAnotherDriveTrustsForTheSameServerIsNotAskedAgain() {
        #expect(HostTrust.decide(offered: key, host: "box.example.com", port: 23, among: [drive(key: key)]) == .alreadyTrusted)
    }

    @Test func theSameKeyOnAnotherHostOrPortIsAsked() {
        #expect(HostTrust.decide(offered: key, host: "other.example.com", port: 23, among: [drive(key: key)]) == .ask)
        #expect(HostTrust.decide(offered: key, host: "box.example.com", port: 22, among: [drive(key: key)]) == .ask)
    }

    @Test func aDifferentKeyIsAsked() {
        #expect(HostTrust.decide(offered: key + "x", host: "box.example.com", port: 23, among: [drive(key: key)]) == .ask)
    }

    @Test func noSavedDrivesMeansAsk() {
        #expect(HostTrust.decide(offered: key, host: "box.example.com", port: 23, among: []) == .ask)
        #expect(HostTrust.decide(offered: key, host: "box.example.com", port: 23, among: [drive(key: nil)]) == .ask)
    }

    @Test func hostCaseDoesntMatter() {
        #expect(HostTrust.decide(offered: key, host: "BOX.example.com", port: 23, among: [drive(key: key)]) == .alreadyTrusted)
    }
}
