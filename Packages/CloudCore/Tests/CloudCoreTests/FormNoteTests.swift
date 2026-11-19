// Apache 2 license - developer@infinitecontext.com

import Foundation
import Testing
@testable import CloudCore

/// A connection problem in a form is one short, calm line under the field it's about, with the
/// whole explanation one click away. It never names a cause a check didn't prove.
@Suite struct FormNoteTests {
    private func finding(_ kind: ConnectionFinding.Kind, host: String = "nas.tail1234.ts.net") -> ConnectionFinding {
        ConnectionFinding(
            kind: kind, host: host, port: 22, isSFTP: true, device: .mac, otherServersOnline: false,
            steps: [ConnectionFinding.Step(title: "Port 22", result: "No answer", mark: .failed)],
            checked: Date(timeIntervalSince1970: 0))
    }

    @Test func everyKindHasAShortSentenceAndAField() {
        for kind in ConnectionFinding.Kind.allCases {
            let found = finding(kind)
            #expect(!found.short.isEmpty, "\(kind)")
            #expect(found.short != found.sentence, "\(kind)")
        }
    }

    /// One clause, short enough for a line under a field, and never a guess at the cause.
    @Test func aShortSentenceIsOneClause() {
        for kind in ConnectionFinding.Kind.allCases {
            let short = finding(kind).short
            #expect(short.count <= 80, "\(kind): \(short)")
            #expect(!short.contains(". "), "\(kind): \(short)")
            #expect(!short.contains(" may "), "\(kind): \(short)")
        }
    }

    @Test func aSilentTailnetPeerPointsAtTheAddress() {
        let found = finding(.tailnetPeerSilent)
        #expect(found.field == .address)
        #expect(found.short == "Nothing answers at this Tailscale address")
    }

    @Test func thisDevicesProblemsPointAtThisDevice() {
        #expect(finding(.tailscaleOff).field == .thisDevice)
        #expect(finding(.noNetwork).field == .thisDevice)
    }

    @Test func aRefusedPortPointsAtThePort() {
        #expect(finding(.refused).field == .port)
        #expect(finding(.refused).short == "Nothing accepts connections on this port")
    }

    @Test func aNoteKeepsTheWholeExplanationForDetails() {
        let found = finding(.noAnswer)
        let note = FormNote(found)
        #expect(note.text == found.short)
        #expect(note.details == found.sentence)
        #expect(note.steps == found.steps)
        #expect(note.field == .port)
    }

    @Test func aRefusedSignInPointsAtTheSignIn() {
        #expect(FormNote.forError(RemoteError.unauthorized).field == .signIn)
        #expect(FormNote.forError(RemoteError.notFound(.root)).field == .folder)
    }
}

/// A server's Tailscale address can change. Its Tailscale name, recorded while it worked, finds
/// the new one, and only a new Tailscale address is offered.
@Suite struct MovedTailnetAddressTests {
    @Test func aNewTailnetAddressIsOfferedOnlyWhenItsNameMovedToAnotherTailnetAddress() {
        #expect(TailnetUse.movedAddress(saved: "100.64.1.2", name: "nas.tail1234.ts.net", found: ["100.64.9.9"]) == "100.64.9.9")
    }

    @Test func noOfferWhenTheNameIsUnknownOrUnchanged() {
        #expect(TailnetUse.movedAddress(saved: "100.64.1.2", name: nil, found: ["100.64.9.9"]) == nil)
        #expect(TailnetUse.movedAddress(saved: "100.64.1.2", name: "nas.tail1234.ts.net", found: ["100.64.1.2"]) == nil)
        #expect(TailnetUse.movedAddress(saved: "100.64.1.2", name: "nas.tail1234.ts.net", found: []) == nil)
    }

    /// Only a Tailscale address saved as an address can move this way. A name follows by itself.
    @Test func noOfferForANameOrAnAddressOffTheTailnet() {
        #expect(TailnetUse.movedAddress(saved: "nas.tail1234.ts.net", name: "nas.tail1234.ts.net", found: ["100.64.9.9"]) == nil)
        #expect(TailnetUse.movedAddress(saved: "100.64.1.2", name: "nas.tail1234.ts.net", found: ["192.168.1.5"]) == nil)
    }

    @Test func aRecordedNameIsKept() throws {
        var use = TailnetUse()
        let drive = UUID()
        use.noteName("nas.tail1234.ts.net.", of: drive)
        #expect(use.name(of: drive) == "nas.tail1234.ts.net")
        let read = try JSONDecoder().decode(TailnetUse.self, from: JSONEncoder().encode(use))
        #expect(read.name(of: drive) == "nas.tail1234.ts.net")
    }

    @Test func onlyATailscaleNameIsRecorded() {
        var use = TailnetUse()
        let drive = UUID()
        use.noteName("router.home.arpa", of: drive)
        #expect(use.name(of: drive) == nil)
    }
}
