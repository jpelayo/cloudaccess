// Apache 2 license - developer@infinitecontext.com

import Foundation

/// Which device a sentence talks about. Each has its own sentences, so each reads whole.
public enum DeviceKind: Sendable {
    case mac
    case iPhone
}

/// What a check of one server found, step by step. Each step after the first only ran because
/// the one before it passed, so a missing step was never reached.
public struct ConnectionFacts: Equatable, Sendable {
    /// Where the server's address says it is.
    public enum Place: Equatable, Sendable {
        /// A `.ts.net` name, which only Tailscale can look up.
        case tailscaleName
        /// An address in Tailscale's own IPv6 range.
        case tailscaleAddress
        /// An address in 100.64.0.0/10, which Tailscale uses, and some other VPNs and carriers.
        case sharedVPNAddress
        /// A `.local` name, answered by devices on the same network.
        case localName
        /// An address only reachable on a local network, such as 192.168.1.20.
        case privateAddress
        /// Anything else: a name or an address on the internet.
        case elsewhere
    }

    public enum Lookup: Equatable, Sendable {
        /// The host is an address, so there was nothing to look up.
        case notNeeded
        case found(String)
        /// The name doesn't exist.
        case notFound
        /// Nothing answered the lookup in time.
        case noAnswer
    }

    /// Which way traffic for the server would leave this device.
    public enum Route: Equatable, Sendable {
        case tailnet
        case otherTunnel
        case ownNetwork
        case router
        case unroutable
    }

    public enum Port: Equatable, Sendable {
        case open
        case refused
        case hostDown
        case timedOut
        case localNetworkDenied
        case noRoute
    }

    public enum Answer: Equatable, Sendable {
        case ssh
        case notSSH
        case closed
        case silent
        case tls
        case certificateExpired
        case certificateUntrusted
        case certificateWrongName
        case notTLS
        /// Plain http, or a step that wasn't due yet: nothing was asked.
        case notAsked
    }

    public var network: DeviceNetwork
    public var place: Place
    /// Whether the server's address is on one of this device's own networks.
    public var isOnOwnNetwork = false
    public var lookup: Lookup?
    public var route: Route?
    public var port: Port?
    public var answer: Answer?
    /// When the server's certificate expired, for an answer that says it did.
    public var certificateExpiry: Date?

    public init(
        network: DeviceNetwork, place: Place, isOnOwnNetwork: Bool = false, lookup: Lookup? = nil,
        route: Route? = nil, port: Port? = nil, answer: Answer? = nil, certificateExpiry: Date? = nil
    ) {
        self.network = network
        self.place = place
        self.isOnOwnNetwork = isOnOwnNetwork
        self.lookup = lookup
        self.route = route
        self.port = port
        self.answer = answer
        self.certificateExpiry = certificateExpiry
    }
}

/// Why a server can't be reached, as far as checking proved it, and nothing further. When the
/// evidence fits several causes, the sentence names them all instead of picking one.
public struct ConnectionFinding: Equatable, Sendable {
    public enum Kind: Equatable, Sendable, CaseIterable {
        // This device: one fix mends every drive it touches.
        case noNetwork
        case mobileDataNotAllowed
        case wifiNotAllowed
        case tailscaleOff
        case localNetworkDenied
        // This server.
        case tailscaleBypassed
        case tailnetPeerSilent
        case tailnetNameUnknown
        case nameNotFound
        case nameNotAnswered
        case localNameSilent
        case privateAddressElsewhere
        case noRoute
        case nothingAnswersHere
        case refused
        case noAnswer
        case notSFTP
        case closedAtOnce
        case silentService
        case certificateExpired
        case certificateUntrusted
        case certificateWrongName
        case notHTTPS
        case notWebDAV
        case tooSlow
        case couldntTell
    }

    /// Where a finding is shown: app-wide for this device, or only with the drive.
    public enum Scope: Equatable, Sendable {
        case device
        case server
    }

    /// What a person can do about it from the app.
    public enum Action: Equatable, Sendable {
        case openTailscale
        case openLocalNetworkSettings
        /// The app's own page in the iPhone's Settings, where mobile data and Wi-Fi are allowed.
        case openAppSettings
        case editDrive
    }

    /// One step of the check, for the drive's Connection card.
    public struct Step: Equatable, Sendable {
        public enum Mark: Equatable, Sendable {
            case passed
            case failed
            case notReached
        }

        public var title: String
        public var result: String
        public var mark: Mark

        public init(title: String, result: String, mark: Mark) {
            self.title = title
            self.result = result
            self.mark = mark
        }
    }

    public var kind: Kind
    public var host: String
    public var port: Int
    public var isSFTP: Bool
    public var device: DeviceKind
    /// Another drive, on another server, connected at the last poll.
    public var otherServersOnline: Bool
    public var steps: [Step]
    public var checked: Date
    /// When the server's certificate expired, if the check read it.
    public var certificateExpiry: Date? = nil

    public var scope: Scope {
        switch kind {
        case .noNetwork, .mobileDataNotAllowed, .wifiNotAllowed, .tailscaleOff, .localNetworkDenied: .device
        default: .server
        }
    }

    /// Nothing can connect while this lasts, so the whole app shows it.
    public var stopsEveryDrive: Bool {
        kind == .noNetwork || kind == .mobileDataNotAllowed || kind == .wifiNotAllowed
    }

    public var action: Action? {
        switch kind {
        case .tailscaleOff: .openTailscale
        case .localNetworkDenied: .openLocalNetworkSettings
        case .mobileDataNotAllowed, .wifiNotAllowed: .openAppSettings
        case .nameNotFound, .refused, .notSFTP, .notHTTPS, .privateAddressElsewhere: .editDrive
        default: nil
        }
    }

    /// Why this device has no network at all, with no server in it, for the app-wide warning.
    public static func forDevice(_ network: DeviceNetwork, device: DeviceKind, checked: Date = Date()) -> ConnectionFinding {
        decide(
            ConnectionFacts(network: network, place: .elsewhere), engine: .unknown, host: "", port: 0,
            isSFTP: false, device: device, otherServersOnline: false, checked: checked)
    }

    /// Whether a failure is one a check can explain: a server that couldn't be reached. A refused
    /// sign-in, a changed server identity or an encryption problem reached the server, and has
    /// its own words.
    public static func isFor(_ error: Error) -> Bool {
        reason(of: error) != nil
    }

    /// Why the engine couldn't reach the server, or nil for any other failure.
    public static func reason(of error: Error) -> UnreachableReason? {
        if case RemoteError.unreachable(_, let reason) = error {
            return reason
        }
        return nil
    }

    /// Decides the finding from what the check saw. Every branch needs the step that proves it,
    /// and a cause nothing proved is never named.
    /// - Parameters:
    ///   - engine: Why the engine itself last failed, used only once every step passed.
    ///   - usesTLS: Whether a WebDAV drive uses https. Nil means it does.
    public static func decide(
        _ facts: ConnectionFacts, engine: UnreachableReason, host: String, port: Int, isSFTP: Bool,
        usesTLS: Bool? = nil, device: DeviceKind, otherServersOnline: Bool, checked: Date = Date()
    ) -> ConnectionFinding {
        let kind = kind(facts, engine: engine)
        let chain = Chain(host: host, port: port, isSFTP: isSFTP, usesTLS: !isSFTP && (usesTLS ?? true), device: device)
        return ConnectionFinding(
            kind: kind, host: host, port: port, isSFTP: isSFTP, device: device,
            otherServersOnline: otherServersOnline, steps: steps(facts, kind: kind, chain: chain),
            checked: checked, certificateExpiry: facts.certificateExpiry)
    }

    /// What a drive's connection goes through, in order, so each step can be listed, reached or not.
    struct Chain {
        var host: String
        var port: Int
        var isSFTP: Bool
        var usesTLS: Bool
        var device: DeviceKind
    }

    static func kind(_ facts: ConnectionFacts, engine: UnreachableReason) -> Kind {
        let network = facts.network
        guard network.isUp else {
            switch network.unsatisfied {
            case .cellularDenied: return .mobileDataNotAllowed
            case .wifiDenied: return .wifiNotAllowed
            case .localNetworkDenied: return .localNetworkDenied
            default: return .noNetwork
            }
        }
        let viaTailnet = [.tailscaleName, .tailscaleAddress, .sharedVPNAddress].contains(facts.place)
        // Proved only by this device having no tailnet address at all.
        if viaTailnet && !network.hasTailnetAddress {
            return .tailscaleOff
        }

        switch facts.lookup {
        case .notFound?:
            switch facts.place {
            case .tailscaleName: return .tailnetNameUnknown
            case .localName: return facts.port == .localNetworkDenied ? .localNetworkDenied : .localNameSilent
            default: return .nameNotFound
            }
        case .noAnswer?:
            if facts.place == .localName {
                return facts.port == .localNetworkDenied ? .localNetworkDenied : .localNameSilent
            }
            return .nameNotAnswered
        case .notNeeded?, .found?, nil:
            break
        }

        switch facts.route {
        case .unroutable?:
            return facts.place == .privateAddress && !facts.isOnOwnNetwork ? .privateAddressElsewhere : .noRoute
        case let route? where viaTailnet && route != .tailnet:
            return .tailscaleBypassed
        case .router? where facts.place == .privateAddress && !facts.isOnOwnNetwork
            && [ConnectionFacts.Port.timedOut, .hostDown, .noRoute].contains(facts.port):
            // A private address sent to the router isn't on this network, and nothing answered.
            return .privateAddressElsewhere
        default:
            break
        }

        switch facts.port {
        case .localNetworkDenied?:
            return .localNetworkDenied
        case .refused?:
            return .refused
        case .noRoute?:
            return .noRoute
        case .hostDown?:
            if facts.route == .tailnet { return .tailnetPeerSilent }
            return facts.route == .ownNetwork || facts.isOnOwnNetwork ? .nothingAnswersHere : .noAnswer
        case .timedOut?:
            return facts.route == .tailnet ? .tailnetPeerSilent : .noAnswer
        case .open?, nil:
            break
        }

        switch facts.answer {
        case .notSSH?: return .notSFTP
        case .closed?: return .closedAtOnce
        case .silent?: return .silentService
        case .certificateExpired?: return .certificateExpired
        case .certificateUntrusted?: return .certificateUntrusted
        case .certificateWrongName?: return .certificateWrongName
        case .notTLS?: return .notHTTPS
        case .ssh?, .tls?, .notAsked?, nil: break
        }

        // Every step passed, so only the engine's own failure is left to go on.
        switch engine {
        case .tooSlow, .timedOut, .connectionLost: return .tooSlow
        case .notWebDAV: return .notWebDAV
        case .certificateExpired: return .certificateExpired
        case .certificateUntrusted: return .certificateUntrusted
        case .certificateWrongName: return .certificateWrongName
        case .notTLS: return .notHTTPS
        case .connectionReset, .sshHandshake: return .closedAtOnce
        case .refused: return .refused
        default: return .couldntTell
        }
    }

    /// Every step a connection goes through, as a person reads them. Once one fails, each later
    /// step is still listed, as not checked, so nothing after a failure looks fine. When every
    /// check passes, the drive's own request is the step that failed: without it, a row of green
    /// beside "not connected" says nothing.
    static func steps(_ facts: ConnectionFacts, kind: Kind, chain: Chain) -> [Step] {
        var steps: [Step] = []
        var hasFailed = false
        func add(_ title: String, _ result: String, _ mark: Step.Mark) {
            if hasFailed {
                steps.append(Step(title: title, result: Words.text("Not checked"), mark: .notReached))
                return
            }
            steps.append(Step(title: title, result: result, mark: mark))
            if mark == .failed { hasFailed = true }
        }
        func notChecked(_ title: String) {
            add(title, Words.text("Not checked"), .notReached)
        }

        let network = Words.text(chain.device == .mac ? "This Mac's network" : "This iPhone's network")
        if facts.network.isUp {
            add(network, Words.text("Connected"), .passed)
        } else {
            let denied: [DeviceNetwork.Unsatisfied?] = [.cellularDenied, .wifiDenied, .localNetworkDenied]
            add(network, Words.text(denied.contains(facts.network.unsatisfied) ? "Not allowed" : "Not connected"), .failed)
        }

        if [.tailscaleName, .tailscaleAddress, .sharedVPNAddress].contains(facts.place) {
            let on = facts.network.hasTailnetAddress
            add("Tailscale", Words.text(on ? "On" : "Off"), on ? .passed : .failed)
        }

        // An address has nothing to look up.
        if IPRange.bytes(of: chain.host) == nil {
            let name = Words.text("Name")
            switch facts.lookup {
            case .found?, .notNeeded?:
                add(name, Words.text("Found"), .passed)
            case .notFound?:
                add(name, Words.text("Doesn't exist"), .failed)
            case .noAnswer?:
                add(name, Words.text(facts.port == .localNetworkDenied ? "Not allowed" : "No answer"), .failed)
            case nil:
                notChecked(name)
            }
        }

        let routeTitle = Words.text("Route")
        if let route = facts.route {
            let result: String
            switch route {
            case .tailnet: result = Words.text("Through Tailscale")
            case .otherTunnel: result = Words.text("Through a VPN")
            case .ownNetwork: result = Words.text("On this network")
            case .router: result = Words.text("Through the router")
            case .unroutable: result = Words.text("None")
            }
            add(routeTitle, result, route == .unroutable || kind == .tailscaleBypassed ? .failed : .passed)
        } else {
            notChecked(routeTitle)
        }

        let portTitle = Words.format("Port %lld", chain.port)
        switch facts.port {
        case .open?:
            add(portTitle, Words.text("Accepts connections"), .passed)
        case .refused?:
            add(portTitle, Words.text("Refused"), .failed)
        case .hostDown?, .timedOut?:
            add(portTitle, Words.text("No answer"), .failed)
        case .localNetworkDenied?:
            add(portTitle, Words.text("Not allowed"), .failed)
        case .noRoute?:
            add(portTitle, Words.text("No route"), .failed)
        case nil:
            notChecked(portTitle)
        }

        let serviceTitle: String? = chain.isSFTP ? Words.text("SFTP service") : chain.usesTLS ? "HTTPS" : nil
        if let serviceTitle {
            switch facts.answer {
            case .ssh?, .tls?:
                add(serviceTitle, Words.text("Answered"), .passed)
            case .notSSH?:
                add(serviceTitle, Words.text("Not SFTP"), .failed)
            case .closed?:
                add(serviceTitle, Words.text("Closed the connection"), .failed)
            case .silent?:
                add(serviceTitle, Words.text("No answer"), .failed)
            case .certificateExpired?:
                add(serviceTitle, Words.text("Certificate expired"), .failed)
            case .certificateUntrusted?:
                add(serviceTitle, Words.text("Certificate not trusted"), .failed)
            case .certificateWrongName?:
                add(serviceTitle, Words.text("Certificate for another name"), .failed)
            case .notTLS?:
                add(serviceTitle, Words.text("Not HTTPS"), .failed)
            case .notAsked?, nil:
                // Not due to be asked this time. The engine's own error can still prove it.
                switch kind {
                case .certificateExpired: add(serviceTitle, Words.text("Certificate expired"), .failed)
                case .certificateUntrusted: add(serviceTitle, Words.text("Certificate not trusted"), .failed)
                case .certificateWrongName: add(serviceTitle, Words.text("Certificate for another name"), .failed)
                case .notHTTPS: add(serviceTitle, Words.text("Not HTTPS"), .failed)
                default: notChecked(serviceTitle)
                }
            }
        }

        let request = chain.isSFTP ? Words.text("Sign-in") : "WebDAV"
        let result: String
        switch kind {
        case .closedAtOnce: result = Words.text("Closed the connection")
        case .tooSlow: result = Words.text("Too slow")
        case .notWebDAV: result = Words.text("Unexpected answer")
        case .refused: result = Words.text("Refused")
        default: result = Words.text("Failed")
        }
        add(request, result, .failed)
        return steps
    }

    /// The finding in a person's words, in the language shown.
    public var sentence: String {
        let mac = device == .mac
        let shownHost = port == (isSFTP ? 22 : 443) ? host : "\(host):\(port)"
        switch kind {
        case .noNetwork:
            return Words.text(mac ? "This Mac isn't connected to a network." : "This iPhone isn't connected to a network.")
        case .mobileDataNotAllowed:
            return Words.text("CloudWanderer isn't allowed to use mobile data. Turn it on in Settings, CloudWanderer.")
        case .wifiNotAllowed:
            return Words.text("CloudWanderer isn't allowed to use Wi-Fi. Turn it on in Settings, CloudWanderer.")
        case .tailscaleOff:
            if Tailnet.isTailscaleOnly(host: host) {
                return Words.format(mac ? "Tailscale is off on this Mac. %@ can only be reached through Tailscale."
                    : "Tailscale is off on this iPhone. %@ can only be reached through Tailscale.", host)
            }
            return Words.format(mac ? "Tailscale is off on this Mac. %@ can only be reached through Tailscale or the VPN that reaches it."
                : "Tailscale is off on this iPhone. %@ can only be reached through Tailscale or the VPN that reaches it.", host)
        case .localNetworkDenied:
            return Words.text(mac
                ? "CloudAccess isn't allowed to reach devices on your local network. Turn it on in System Settings, Privacy & Security, Local Network."
                : "CloudWanderer isn't allowed to reach devices on your local network. Turn it on in Settings, CloudWanderer, Local Network.")
        case .tailscaleBypassed:
            return Words.format(mac ? "Tailscale is on, but this Mac sends traffic for %@ another way. Another VPN may be in the way."
                : "Tailscale is on, but this iPhone sends traffic for %@ another way. Another VPN may be in the way.", host)
        case .tailnetPeerSilent:
            return Words.format("Tailscale is on, but %@ doesn't answer through it. It may be off, asleep, or signed out of Tailscale.", host)
        case .tailnetNameUnknown:
            return Words.format("Tailscale is on, but it doesn't know a device named %@. It may have been renamed or removed from your tailnet.", host)
        case .nameNotFound:
            return Words.format("No server named %@ exists. Check the address in the drive's settings.", host)
        case .nameNotAnswered:
            if otherServersOnline {
                return Words.format("Looking up the name %@ got no answer, though your other drives connect. The name's own server may be down.", host)
            }
            return Words.format("Looking up the name %@ got no answer. The network may need a sign-in page, its router may be down, or the name's own server may be.", host)
        case .localNameSilent:
            return Words.format("No device named %@ answered on this network. It may be off, or on another network.", host)
        case .privateAddressElsewhere:
            return Words.format(mac ? "%@ is on a different local network from the one this Mac is on. Connect to that network, or to a VPN that reaches it."
                : "%@ is on a different local network from the one this iPhone is on. Connect to that network, or to a VPN that reaches it.", host)
        case .noRoute:
            return Words.format(mac ? "This Mac has no way to reach %@ from the network it's on." : "This iPhone has no way to reach %@ from the network it's on.", host)
        case .nothingAnswersHere:
            return Words.format("Nothing answers at %@ on this network. It may be off or asleep, or have a new address.", host)
        case .refused:
            return Words.format(isSFTP
                ? "%1$@ is on, but nothing accepts connections on port %2$lld. Check that its SFTP service is running, and the port."
                : "%1$@ is on, but nothing accepts connections on port %2$lld. Check that its WebDAV service is running, and the port.", host, port)
        case .noAnswer:
            let first = Words.format("%1$@ doesn't answer on port %2$lld. The server or its network may be down, or a firewall may be blocking the port.", host, port)
            guard otherServersOnline else { return first }
            return first + " " + Words.text(mac ? "Your other drives connect, so this Mac's network is working." : "Your other drives connect, so this iPhone's network is working.")
        case .notSFTP:
            return Words.format("Something answers on port %2$lld at %1$@, but it isn't an SFTP server.", host, port)
        case .closedAtOnce:
            return Words.format(mac ? "%@ closed the connection straight away. It may limit connections, or be blocking this Mac."
                : "%@ closed the connection straight away. It may limit connections, or be blocking this iPhone.", shownHost)
        case .silentService:
            return Words.format(isSFTP
                ? "%1$@ accepts connections on port %2$lld, but doesn't answer. It may be busy, or it isn't an SFTP server."
                : "%1$@ accepts connections on port %2$lld, but doesn't answer. It may be busy, or it isn't a WebDAV server.", host, port)
        case .certificateExpired:
            guard let certificateExpiry else {
                return Words.format("The certificate of %@ has expired.", shownHost)
            }
            return Words.format(
                "The certificate of %1$@ expired on %2$@.", shownHost,
                certificateExpiry.formatted(date: .long, time: .omitted))
        case .certificateUntrusted:
            return Words.format(mac ? "The certificate of %@ isn't trusted by this Mac." : "The certificate of %@ isn't trusted by this iPhone.", shownHost)
        case .certificateWrongName:
            return Words.format("The certificate presented isn't for %@. The network may be redirecting traffic, for example to a sign-in page.", host)
        case .notHTTPS:
            return Words.format("%1$@ doesn't use HTTPS on port %2$lld.", host, port)
        case .notWebDAV:
            return Words.format("Something other than the WebDAV server answered at %@. The network may need a sign-in page.", shownHost)
        case .tooSlow:
            return Words.format("%@ answers, but too slowly. It may be busy, or the connection is very slow.", shownHost)
        case .couldntTell:
            return Words.format(mac ? "%@ can't be reached, and CloudAccess couldn't tell why. The details are in the log."
                : "%@ can't be reached, and CloudWanderer couldn't tell why. What it checked is in the log.", shownHost)
        }
    }

    /// Whether only the server, or the way to it, can mend this, so the app waits and keeps trying
    /// rather than asking a person to change something.
    public var waitsForTheServer: Bool {
        switch kind {
        case .tailnetPeerSilent, .nameNotAnswered, .localNameSilent, .noRoute, .nothingAnswersHere, .noAnswer,
             .closedAtOnce, .silentService, .certificateWrongName, .notWebDAV, .tooSlow, .couldntTell:
            true
        default:
            false
        }
    }

    /// The finding in a few words, for the top of a drive's Information page. The server's name
    /// has a line of its own there, so it's never in here.
    public var title: String {
        let mac = device == .mac
        if waitsForTheServer {
            return Words.text("Waiting for the server")
        }
        switch kind {
        case .noNetwork: return Words.text(mac ? "This Mac has no network" : "This iPhone has no network")
        case .mobileDataNotAllowed: return Words.text("Mobile data isn't allowed")
        case .wifiNotAllowed: return Words.text("Wi-Fi isn't allowed")
        case .tailscaleOff: return Words.text("Tailscale is off")
        case .localNetworkDenied: return Words.text("Local network permission is missing")
        case .tailscaleBypassed: return Words.text("Another VPN is in the way")
        case .tailnetNameUnknown: return Words.text("Tailscale doesn't know that name")
        case .nameNotFound: return Words.text("No server has that name")
        case .privateAddressElsewhere: return Words.text("The server is on another network")
        case .refused: return Words.text(isSFTP ? "The SFTP service isn't running" : "The WebDAV service isn't running")
        case .notSFTP: return Words.text("Not an SFTP server")
        case .notHTTPS: return Words.text("The server doesn't use HTTPS")
        case .certificateExpired: return Words.text("The server's certificate has expired")
        case .certificateUntrusted:
            return Words.text(mac ? "This Mac doesn't trust the certificate" : "This iPhone doesn't trust the certificate")
        default: return Words.text("Waiting for the server")
        }
    }

    /// Why, in a sentence or two under the title, without the server's name.
    public var cause: String {
        let mac = device == .mac
        switch kind {
        case .noNetwork:
            return Words.text(mac
                ? "This Mac isn't connected to any network. The drive connects by itself when it's back."
                : "This iPhone isn't connected to any network. The drive connects by itself when it's back.")
        case .mobileDataNotAllowed, .wifiNotAllowed:
            return sentence
        case .tailscaleOff:
            return Words.text(Tailnet.isTailscaleOnly(host: host)
                ? "This server can only be reached through Tailscale."
                : "This server can only be reached through Tailscale, or the VPN that reaches it.")
        case .localNetworkDenied:
            return Words.text(mac
                ? "CloudAccess isn't allowed to reach devices on your local network."
                : "CloudWanderer isn't allowed to reach devices on your local network.")
        case .tailscaleBypassed:
            return Words.text(mac
                ? "Tailscale is on, but this Mac sends this server's traffic another way. Another VPN may be in the way."
                : "Tailscale is on, but this iPhone sends this server's traffic another way. Another VPN may be in the way.")
        case .tailnetPeerSilent:
            return Words.text("Tailscale is on, but the server doesn't answer through it. It may be off or asleep, or signed out of Tailscale.")
        case .tailnetNameUnknown:
            return Words.text("The device may have been renamed, or removed from your tailnet.")
        case .nameNotFound:
            return Words.text("The drive's address may have a typo.")
        case .nameNotAnswered:
            return Words.text(otherServersOnline
                ? "Looking up the name got no answer, though your other drives connect. The name's own server may be down."
                : "Looking up the name got no answer. The network may need a sign-in page, its router may be down, or the name's own server may be.")
        case .localNameSilent:
            return Words.text("No device with that name answered on this network. It may be off, or on another network.")
        case .privateAddressElsewhere:
            return Words.text(mac
                ? "This address belongs to another local network, not the one this Mac is on. Connect to that network, or to a VPN that reaches it."
                : "This address belongs to another local network, not the one this iPhone is on. Connect to that network, or to a VPN that reaches it.")
        case .noRoute:
            return Words.text(mac
                ? "This Mac has no way to reach the server from the network it's on."
                : "This iPhone has no way to reach the server from the network it's on.")
        case .nothingAnswersHere:
            return Words.text("Nothing answers at that address on this network. The server may be off or asleep, or have a new address.")
        case .refused:
            return Words.format(isSFTP
                ? "The server is on, but nothing accepts connections on port %lld. Check that its SFTP service is running, and the port."
                : "The server is on, but nothing accepts connections on port %lld. Check that its WebDAV service is running, and the port.", port)
        case .noAnswer:
            let first = Words.format("The server doesn't answer on port %lld. It may be off or offline, or a firewall may be blocking the port.", port)
            guard otherServersOnline else { return first }
            return first + " " + Words.text(mac ? "Your other drives connect, so this Mac's network is working." : "Your other drives connect, so this iPhone's network is working.")
        case .notSFTP:
            return Words.format("Something answers on port %lld, but it isn't an SFTP server.", port)
        case .closedAtOnce:
            return Words.text("The server cuts the connection as soon as it starts. Servers do this when they get too many connections at once, or when they block an address for a while.")
        case .silentService:
            return Words.format(isSFTP
                ? "The server accepts connections on port %lld, but doesn't answer. It may be busy, or it isn't an SFTP server."
                : "The server accepts connections on port %lld, but doesn't answer. It may be busy, or it isn't a WebDAV server.", port)
        case .certificateExpired:
            guard let certificateExpiry else {
                return Words.text("Whoever runs the server has to renew it.")
            }
            return Words.format(
                "It expired on %@. Whoever runs the server has to renew it.",
                certificateExpiry.formatted(date: .long, time: .omitted))
        case .certificateUntrusted:
            return Words.text(mac
                ? "This Mac doesn't trust the server's certificate, so nothing is sent to it."
                : "This iPhone doesn't trust the server's certificate, so nothing is sent to it.")
        case .certificateWrongName:
            return Words.text("The certificate received isn't this server's. The network may be redirecting traffic, for example to a sign-in page.")
        case .notHTTPS:
            return Words.format("The server doesn't use HTTPS on port %lld.", port)
        case .notWebDAV:
            return Words.text("Something other than the WebDAV server answered. The network may need a sign-in page.")
        case .tooSlow:
            return Words.text("The server answers, but too slowly. It may be busy, or the connection is very slow.")
        case .couldntTell:
            return Words.text(mac
                ? "CloudAccess couldn't connect, and couldn't tell why. The details are in the log."
                : "CloudWanderer couldn't connect, and couldn't tell why. What it checked is in the log.")
        }
    }

    /// A few words for a drive's row, in the language shown.
    public var shortLabel: String {
        switch kind {
        case .noNetwork, .mobileDataNotAllowed, .wifiNotAllowed: Words.text("no network")
        case .tailscaleOff: Words.text("Tailscale off")
        case .localNetworkDenied: Words.text("local network not allowed")
        case .refused: Words.text("service stopped")
        case .certificateExpired, .certificateUntrusted, .certificateWrongName: Words.text("certificate problem")
        case .nameNotFound, .tailnetNameUnknown: Words.text("name not found")
        case .privateAddressElsewhere: Words.text("on another network")
        default: Words.text("server not answering")
        }
    }

    /// For the log, in English: the finding and each step's mark, with no host and no address.
    public var logLine: String {
        let marks = steps.map { step -> String in
            switch step.mark {
            case .passed: "ok"
            case .failed: "failed"
            case .notReached: "not reached"
            }
        }
        return "Connection check: \(kind), steps \(marks.joined(separator: " "))"
    }
}
