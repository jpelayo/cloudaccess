// Apache 2 license - developer@infinitecontext.com

import Foundation
import Testing
@testable import CloudCore

/// A drive can need Tailscale without its address saying so: a MagicDNS short name, a custom
/// name, or a LAN address behind a subnet route. Having reached it through Tailscale is the proof.
@Suite struct TailnetUseTests {
    static let wifi = DeviceNetwork.Interface(name: "en0", address: "192.168.30.10", prefixLength: 24)
    static let tailscale = DeviceNetwork.Interface(name: "utun4", address: "100.101.102.103", prefixLength: 32)
    static let up = DeviceNetwork(isUp: true, interfaces: [wifi])
    static let upWithTailscale = DeviceNetwork(isUp: true, interfaces: [wifi, tailscale])

    private let drive = UUID()
    private let day: TimeInterval = 24 * 60 * 60
    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func kind(_ facts: ConnectionFacts, host: String = "nas") -> ConnectionFinding.Kind {
        ConnectionFinding.decide(
            facts, engine: .timedOut, host: host, port: 22, isSFTP: true, usesTLS: false, device: .mac,
            otherServersOnline: false, checked: start
        ).kind
    }

    @Test func aDriveReachedThroughTailscaleIsBlamedWhenItsOff() {
        var facts = ConnectionFacts(network: Self.up, place: .elsewhere, lookup: .notFound)
        facts.reachedThroughTailnet = true
        #expect(kind(facts) == .tailscaleOff)
    }

    @Test func aDriveNeverReachedThroughTailscaleKeepsItsOwnFinding() {
        let facts = ConnectionFacts(network: Self.up, place: .elsewhere, lookup: .notFound)
        #expect(kind(facts) == .nameNotFound)
    }

    /// With Tailscale on, having used it proves nothing: the server may be the one that's off.
    @Test func tailscaleOnIsNeverBlamedForADriveThatUsedIt() {
        var facts = ConnectionFacts(network: Self.upWithTailscale, place: .elsewhere, lookup: .notFound)
        facts.reachedThroughTailnet = true
        #expect(kind(facts) != .tailscaleOff)
    }

    @Test func theStepsShowTailscaleOffForADriveThatUsedIt() {
        var facts = ConnectionFacts(network: Self.up, place: .elsewhere, lookup: .notFound)
        facts.reachedThroughTailnet = true
        let finding = ConnectionFinding.decide(
            facts, engine: .timedOut, host: "nas", port: 22, isSFTP: true, usesTLS: false, device: .mac,
            otherServersOnline: false, checked: start)
        #expect(finding.steps.contains { $0.title == "Tailscale" && $0.mark == .failed })
    }

    @Test func aDirectRouteLaterDoesntForgetTailscale() {
        var use = TailnetUse()
        use.note(drive, throughTailnet: true, at: start)
        use.note(drive, throughTailnet: false, at: start.addingTimeInterval(day))
        #expect(use.usesTailnet(drive, at: start.addingTimeInterval(2 * day)))
    }

    @Test func tailscaleUseIsForgottenAfter90Days() {
        var use = TailnetUse()
        use.note(drive, throughTailnet: true, at: start)
        #expect(use.usesTailnet(drive, at: start.addingTimeInterval(89 * day)))
        #expect(!use.usesTailnet(drive, at: start.addingTimeInterval(91 * day)))
    }

    @Test func aDriveNeverSeenThroughTailscaleDoesntUseIt() {
        var use = TailnetUse()
        use.note(drive, throughTailnet: false, at: start)
        #expect(!use.usesTailnet(drive, at: start))
    }

    @Test func aRemovedDriveIsForgotten() {
        var use = TailnetUse()
        use.note(drive, throughTailnet: true, at: start)
        use.keep(only: [])
        #expect(!use.usesTailnet(drive, at: start))
    }

    @Test func aTailnetAddressOrRouteIsThroughTailscale() {
        #expect(TailnetUse.isThroughTailnet(address: "100.90.1.2", route: .router))
        #expect(TailnetUse.isThroughTailnet(address: "192.168.1.20", route: .tailnet))
        #expect(!TailnetUse.isThroughTailnet(address: "192.168.1.20", route: .ownNetwork))
    }

    @Test func aTailnetAddressAppearingCountsAsANetworkChange() {
        var presence = TailnetPresence()
        let first = presence.changed(to: false)
        let appeared = presence.changed(to: true)
        let stayed = presence.changed(to: true)
        let went = presence.changed(to: false)
        #expect(!first)
        #expect(appeared)
        #expect(!stayed)
        #expect(went)
    }

    @Test func itSurvivesBeingSaved() throws {
        var use = TailnetUse()
        use.note(drive, throughTailnet: true, at: start)
        let read = try JSONDecoder().decode(TailnetUse.self, from: JSONEncoder().encode(use))
        #expect(read == use)
    }
}

/// While Tailscale is off, a drive failing in a way a missing tunnel could cause gets a hint that
/// names Tailscale as a possibility. Nothing else does.
@Suite struct TailscaleHintTests {
    private func finding(_ kind: ConnectionFinding.Kind) -> ConnectionFinding {
        ConnectionFinding(
            kind: kind, host: "nas", port: 22, isSFTP: true, device: .mac, otherServersOnline: false,
            steps: [], checked: Date(timeIntervalSince1970: 0))
    }

    private func hint(
        _ findings: [ConnectionFinding], installed: Bool = true, tailnetUp: Bool = false, used: Bool = true
    ) -> AppWideWarning? {
        AppWideWarning.tailscaleHint(
            findings: findings, isTailscaleInstalled: installed, hasTailnetAddress: tailnetUp,
            someDriveUsesTailnet: used)
    }

    @Test func theHintShowsWhenTailscaleIsOffAndADriveUsesIt() {
        let warning = hint([finding(.nameNotFound), finding(.noRoute)])
        #expect(warning == .tailscaleMayHelp(drives: 2))
        #expect(warning?.title == "Tailscale is off on this Mac. 2 drives can't connect, and may need it.")
    }

    @Test func noHintWhileTailscaleIsOn() {
        #expect(hint([finding(.nameNotFound)], tailnetUp: true) == nil)
    }

    @Test func noHintWhenNoDriveUsesTailscale() {
        #expect(hint([finding(.nameNotFound)], used: false) == nil)
    }

    @Test func noHintWithoutTailscaleInstalled() {
        #expect(hint([finding(.nameNotFound)], installed: false) == nil)
    }

    @Test func noHintForCertificateOrSignInProblems() {
        #expect(hint([finding(.certificateExpired), finding(.refused), finding(.notSFTP)]) == nil)
    }

    @Test func aProvedTailscaleOffNeedsNoHint() {
        #expect(hint([finding(.tailscaleOff)]) == nil)
    }
}
