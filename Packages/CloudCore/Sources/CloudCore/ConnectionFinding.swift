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
    public enum Kind: Equatable, Sendable {
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
    /// - Parameter engine: Why the engine itself last failed, used only once every step passed.
    public static func decide(
        _ facts: ConnectionFacts, engine: UnreachableReason, host: String, port: Int, isSFTP: Bool,
        device: DeviceKind, otherServersOnline: Bool, checked: Date = Date()
    ) -> ConnectionFinding {
        ConnectionFinding(
            kind: kind(facts, engine: engine), host: host, port: port, isSFTP: isSFTP, device: device,
            otherServersOnline: otherServersOnline, steps: steps(facts, port: port, isSFTP: isSFTP, device: device),
            checked: checked, certificateExpiry: facts.certificateExpiry)
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

    /// The check's steps as a person reads them, up to the one that failed.
    static func steps(_ facts: ConnectionFacts, port: Int, isSFTP: Bool, device: DeviceKind) -> [Step] {
        var steps: [Step] = []
        let mac = device == .mac
        let network = Words.text(mac ? "This Mac's network" : "This iPhone's network")
        guard facts.network.isUp else {
            steps.append(Step(title: network, result: Words.text("Not connected"), mark: .failed))
            return steps
        }
        steps.append(Step(title: network, result: Words.text("Connected"), mark: .passed))

        if [.tailscaleName, .tailscaleAddress, .sharedVPNAddress].contains(facts.place) {
            let on = facts.network.hasTailnetAddress
            steps.append(Step(title: "Tailscale", result: Words.text(on ? "On" : "Off"), mark: on ? .passed : .failed))
            if !on { return steps }
        }

        switch facts.lookup {
        case .found?:
            steps.append(Step(title: Words.text("Name"), result: Words.text("Found"), mark: .passed))
        case .notFound?:
            steps.append(Step(title: Words.text("Name"), result: Words.text("Doesn't exist"), mark: .failed))
            return steps
        case .noAnswer?:
            steps.append(Step(title: Words.text("Name"), result: Words.text("No answer"), mark: .failed))
            return steps
        case .notNeeded?, nil:
            break
        }

        if let route = facts.route {
            let result: String
            switch route {
            case .tailnet: result = Words.text("Through Tailscale")
            case .otherTunnel: result = Words.text("Through a VPN")
            case .ownNetwork: result = Words.text("On this network")
            case .router: result = Words.text("Through the router")
            case .unroutable: result = Words.text("None")
            }
            steps.append(Step(title: Words.text("Route"), result: result, mark: route == .unroutable ? .failed : .passed))
            if route == .unroutable { return steps }
        }

        let portTitle = Words.format("Port %lld", port)
        switch facts.port {
        case .open?:
            steps.append(Step(title: portTitle, result: Words.text("Accepts connections"), mark: .passed))
        case .refused?:
            steps.append(Step(title: portTitle, result: Words.text("Refused"), mark: .failed))
        case .hostDown?, .timedOut?:
            steps.append(Step(title: portTitle, result: Words.text("No answer"), mark: .failed))
        case .localNetworkDenied?:
            steps.append(Step(title: portTitle, result: Words.text("Not allowed"), mark: .failed))
        case .noRoute?:
            steps.append(Step(title: portTitle, result: Words.text("No route"), mark: .failed))
        case nil:
            steps.append(Step(title: portTitle, result: Words.text("Not checked"), mark: .notReached))
        }
        guard facts.port == .open else { return steps }

        let serviceTitle = isSFTP ? Words.text("SFTP service") : "HTTPS"
        switch facts.answer {
        case .ssh?, .tls?:
            steps.append(Step(title: serviceTitle, result: Words.text("Answered"), mark: .passed))
        case .notSSH?:
            steps.append(Step(title: serviceTitle, result: Words.text("Not SFTP"), mark: .failed))
        case .closed?:
            steps.append(Step(title: serviceTitle, result: Words.text("Closed the connection"), mark: .failed))
        case .silent?:
            steps.append(Step(title: serviceTitle, result: Words.text("No answer"), mark: .failed))
        case .certificateExpired?:
            steps.append(Step(title: serviceTitle, result: Words.text("Certificate expired"), mark: .failed))
        case .certificateUntrusted?:
            steps.append(Step(title: serviceTitle, result: Words.text("Certificate not trusted"), mark: .failed))
        case .certificateWrongName?:
            steps.append(Step(title: serviceTitle, result: Words.text("Certificate for another name"), mark: .failed))
        case .notTLS?:
            steps.append(Step(title: serviceTitle, result: Words.text("Not HTTPS"), mark: .failed))
        case .notAsked?, nil:
            break
        }
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
