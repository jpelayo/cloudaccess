// Apache 2 license - developer@infinitecontext.com

import Foundation
import Observation

/// Each drive's latest finding, kept up to date by checking after real failures. Both apps own
/// one. Checks run beside the polls, never inside them, and each server is checked once for all
/// the drives on it.
@MainActor @Observable
public final class ConnectionChecks {
    /// What a check of one server does, and what it's given: whether to ask the service.
    typealias Probe = @Sendable (ConnectionCheck.Target, DeviceNetwork, Bool) async -> ConnectionFacts

    /// The latest finding for each drive that can't reach its server.
    public private(set) var findings: [UUID: ConnectionFinding] = [:]
    /// Drives being checked now.
    public private(set) var checking: Set<UUID> = []
    /// Until then a failure is too soon to judge: interfaces take a moment after a wake or a
    /// change of network, and "network unreachable" is expected meanwhile.
    public private(set) var settlingUntil: Date?

    /// Why each drive's engine last failed, which only matters once every step passes.
    private var reasons: [UUID: UnreachableReason] = [:]
    /// When each server's service was last asked for its first answer.
    private var asked: [ConnectionCheck.Target: Date] = [:]
    /// What each server's service last answered, since the last change of network. A check that
    /// isn't due to ask again keeps it, so the finding doesn't change just because it wasn't asked.
    private var answers: [ConnectionCheck.Target: (answer: ConnectionFacts.Answer, expiry: Date?)] = [:]
    /// When this device's network last changed, or it woke. Anything found before then may no
    /// longer hold.
    private var changedAt: Date = .distantPast
    private let device: DeviceKind
    private let now: () -> Date
    private let currentNetwork: @Sendable () async -> DeviceNetwork
    private let probe: Probe
    /// Where each finding is recorded, in English, with no host or address.
    public var log: (String) -> Void = { _ in }

    /// How often a server's service is asked by itself, and when a person presses Check Again.
    /// An SSH server can ban an address that opens connections it never signs in on.
    static let askedByItself: TimeInterval = 600
    static let askedByAPerson: TimeInterval = 30
    /// How old a finding gets before a drive that still fails is checked again. Until then the
    /// poll itself is the recheck: it connects, and a drive that connects has nothing to explain.
    static let recheckAfter: TimeInterval = 300

    public convenience init(device: DeviceKind) {
        self.init(
            device: device, now: { Date() },
            network: { await ConnectionCheck.currentNetwork() },
            probe: { target, network, asks in await ConnectionCheck.run(target, network: network, asksTheService: asks) })
    }

    /// For tests: a clock, this device's network and the check itself, given instead of read.
    init(
        device: DeviceKind, now: @escaping () -> Date, network: @escaping @Sendable () async -> DeviceNetwork,
        probe: @escaping Probe
    ) {
        self.device = device
        self.now = now
        self.currentNetwork = network
        self.probe = probe
    }

    public var isSettling: Bool {
        settlingUntil.map { $0 > now() } ?? false
    }

    /// The network changed, or the device woke: waits this long before judging a failure, and
    /// checks every drive that still fails again, with its server's service asked again.
    public func settle(for seconds: TimeInterval) {
        let start = now()
        let until = start.addingTimeInterval(seconds)
        settlingUntil = max(settlingUntil ?? until, until)
        changedAt = start
        // "Tailscale is off" may have stopped being true, so nothing found before is kept. A
        // drive with no finding is checked on its next failure.
        findings = [:]
        answers = [:]
        // Cleared once it's over, so what's on screen stops saying "Reconnecting…" by itself.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            if let self, let settlingUntil = self.settlingUntil, settlingUntil <= self.now() {
                self.settlingUntil = nil
            }
        }
    }

    /// Something on this device may have changed that no network change shows, such as a switch
    /// in Settings while the app was away. What's shown stays until the next failure checks again.
    public func checkAgainOnNextFailure() {
        changedAt = now()
        answers = [:]
    }

    /// Drives that connected again have nothing to explain.
    public func keep(only offline: Set<UUID>) {
        findings = findings.filter { offline.contains($0.key) }
        reasons = reasons.filter { offline.contains($0.key) }
    }

    /// Drives that couldn't reach their servers, from a poll. Each is checked if it has no finding
    /// yet, the engine's reason changed, or its finding is old; otherwise the poll itself is the
    /// recheck.
    /// - Parameter otherServersOnline: Whether a drive on another server connected.
    /// - Returns: The check it started, if any, for tests to wait on.
    @discardableResult
    public func noteFailures(
        _ failed: [(Connection, Error)], otherServersOnline: @escaping @MainActor (Connection) -> Bool
    ) -> Task<Void, Never>? {
        var due: [Connection] = []
        for (connection, error) in failed {
            guard let reason = ConnectionFinding.reason(of: error) else {
                // It reached the server: a sign-in or a vault problem has its own words.
                findings[connection.id] = nil
                reasons[connection.id] = nil
                continue
            }
            let isOld = findings[connection.id].map {
                $0.checked < changedAt || now().timeIntervalSince($0.checked) >= Self.recheckAfter
            } ?? true
            if isOld || reasons[connection.id] != reason {
                reasons[connection.id] = reason
                due.append(connection)
            }
        }
        guard !due.isEmpty else { return nil }
        return Task { await check(due, byAPerson: false, otherServersOnline: otherServersOnline) }
    }

    /// Checks drives now, one check per server.
    /// - Parameter byAPerson: Check Again was pressed, so the service may be asked sooner.
    public func check(
        _ connections: [Connection], byAPerson: Bool, otherServersOnline: @escaping @MainActor (Connection) -> Bool
    ) async {
        let fresh = connections.filter { !checking.contains($0.id) }
        guard !fresh.isEmpty else { return }
        checking.formUnion(fresh.map(\.id))
        defer { checking.subtract(fresh.map(\.id)) }

        // Another change while waiting moves the end further on.
        while let settlingUntil, settlingUntil > now(), !Task.isCancelled {
            try? await Task.sleep(for: .seconds(settlingUntil.timeIntervalSince(now())))
        }
        let started = now()
        let network = await currentNetwork()
        var byServer: [ConnectionCheck.Target: [Connection]] = [:]
        for connection in fresh {
            if let target = ConnectionCheck.Target(connection) {
                byServer[target, default: []].append(connection)
            }
        }
        let wait = byAPerson ? Self.askedByAPerson : Self.askedByItself
        let plan = byServer.keys.map { target in
            (target, asked[target].map { mayAsk(since: $0, wait: wait, at: started) } ?? true)
        }
        let probe = self.probe
        let results = await withTaskGroup(of: (ConnectionCheck.Target, ConnectionFacts).self) { group in
            for (target, asks) in plan {
                group.addTask { (target, await probe(target, network, asks)) }
            }
            var all: [(ConnectionCheck.Target, ConnectionFacts)] = []
            for await result in group {
                all.append(result)
            }
            return all
        }
        // The network changed while this ran, so what it saw may not hold. The next failure
        // checks again.
        guard started >= changedAt else { return }
        for (target, seen) in results {
            var facts = seen
            if let answer = facts.answer, answer != .notAsked {
                asked[target] = now()
                answers[target] = (answer, facts.certificateExpiry)
            } else if facts.answer == .notAsked, let kept = answers[target] {
                // Not due to ask yet: the last answer since the network changed still stands.
                facts.answer = kept.answer
                facts.certificateExpiry = kept.expiry
            }
            for connection in byServer[target] ?? [] {
                let finding = ConnectionFinding.decide(
                    facts, engine: reasons[connection.id] ?? .unknown, host: target.host, port: target.port,
                    isSFTP: target.isSFTP, usesTLS: target.usesTLS, device: device,
                    otherServersOnline: otherServersOnline(connection),
                    checked: now())
                findings[connection.id] = finding
                log(finding.logLine)
            }
        }
    }

    /// Whether a server's service may be asked again. After a change of network its last answer
    /// may no longer hold, so it's asked again, though never sooner than Check Again could.
    private func mayAsk(since last: Date, wait: TimeInterval, at time: Date) -> Bool {
        let elapsed = time.timeIntervalSince(last)
        return elapsed >= wait || (last < changedAt && elapsed >= Self.askedByAPerson)
    }

    /// A failure in a person's words, for a form that just tried to connect. An unreachable server
    /// is checked first, so the words say which part failed. Anything else keeps its own words.
    public static func explain(_ error: Error, for connection: Connection, device: DeviceKind) async -> String {
        guard let reason = ConnectionFinding.reason(of: error), let target = ConnectionCheck.Target(connection) else {
            return error.localizedDescription
        }
        let network = await ConnectionCheck.currentNetwork()
        let facts = await ConnectionCheck.run(target, network: network, asksTheService: true)
        return ConnectionFinding.decide(
            facts, engine: reason, host: target.host, port: target.port, isSFTP: target.isSFTP,
            usesTLS: target.usesTLS, device: device, otherServersOnline: false
        ).sentence
    }
}
