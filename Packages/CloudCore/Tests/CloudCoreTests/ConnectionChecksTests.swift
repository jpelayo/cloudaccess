// Apache 2 license - developer@infinitecontext.com

import Foundation
import Network
import Synchronization
import Testing
@testable import CloudCore

/// When a drive that still fails is checked again, and how rarely its server's service is asked.
/// What a check finds must never outlive the change that made it untrue, such as Tailscale
/// being turned on while the server stays off.
@MainActor @Suite struct ConnectionChecksTests {
    /// A clock the test moves by hand.
    final class Clock {
        var time = Date(timeIntervalSince1970: 1_000_000)
    }

    /// Stands in for the check of a server whose port is open and that isn't an SFTP server. It
    /// keeps whether each check asked the service.
    final class Server: Sendable {
        private let calls = Mutex<[Bool]>([])

        var asks: [Bool] {
            calls.withLock { $0 }
        }

        func probe(_ network: DeviceNetwork, asks: Bool) -> ConnectionFacts {
            calls.withLock { $0.append(asks) }
            return ConnectionFacts(
                network: network, place: .elsewhere, lookup: .found("203.0.113.5"), route: .router, port: .open,
                answer: asks ? .notSSH : .notAsked)
        }
    }

    let clock = Clock()
    let server = Server()
    let drive = Connection(displayName: "S", endpoint: .sftp(host: "files.example.com", port: 22))
    /// What the engine says for a server that hangs up before signing in.
    let failure = RemoteError.unreachable("x", reason: .sshHandshake)

    private func makeChecks() -> ConnectionChecks {
        let clock = clock
        let server = server
        return ConnectionChecks(
            device: .mac, now: { clock.time }, network: { DeviceNetwork(isUp: true) },
            probe: { _, network, asks in server.probe(network, asks: asks) })
    }

    /// A poll that failed, and the check it started, if any, seen through.
    private func pollFails(_ checks: ConnectionChecks) async {
        await checks.noteFailures([(drive, failure)]) { _ in false }?.value
    }

    @Test func justAfterWakeSaysReconnecting() async {
        let checks = makeChecks()
        await pollFails(checks)
        #expect(checks.findings[drive.id]?.kind == .notSFTP)
        checks.settle(for: 10)
        #expect(checks.isSettling)
        // What was found before the wake may no longer hold, so none of it is shown.
        #expect(checks.findings.isEmpty)
        clock.time += 11
        #expect(!checks.isSettling)
    }

    @Test func theSameFailureIsntCheckedOnEveryPoll() async {
        let checks = makeChecks()
        await pollFails(checks)
        clock.time += 30
        await pollFails(checks)
        #expect(server.asks == [true])
    }

    /// The case that matters: Tailscale is turned on, the server stays off, and the engine's
    /// reason stays the same. "Tailscale is off" must not stay on screen.
    @Test func aChangeOfNetworkChecksEveryDriveAgain() async {
        let checks = makeChecks()
        await pollFails(checks)
        clock.time += 31
        checks.settle(for: 0)
        await pollFails(checks)
        // The service is asked again too, since its answer was from before the change.
        #expect(server.asks == [true, true])
        #expect(checks.findings[drive.id]?.kind == .notSFTP)
    }

    @Test func anOldFindingIsCheckedAgainButTheServiceOnlyRarely() async {
        let checks = makeChecks()
        await pollFails(checks)
        clock.time += ConnectionChecks.recheckAfter
        await pollFails(checks)
        #expect(server.asks == [true, false])
        // Not asked this time, so its last answer stands, and the finding doesn't change.
        #expect(checks.findings[drive.id]?.kind == .notSFTP)
        #expect(checks.findings[drive.id]?.checked == clock.time)
        clock.time += ConnectionChecks.recheckAfter
        await pollFails(checks)
        #expect(server.asks == [true, false, true])
    }

    @Test func checkAgainAsksSoonerButNotEveryTime() async {
        let checks = makeChecks()
        await pollFails(checks)
        clock.time += 10
        await checks.check([drive], byAPerson: true) { _ in false }
        clock.time += 30
        await checks.check([drive], byAPerson: true) { _ in false }
        #expect(server.asks == [true, false, true])
    }

    /// Coming back to the app after Settings: what's shown stays until the next failure checks.
    @Test func comingBackChecksAgainOnTheNextFailure() async {
        let checks = makeChecks()
        await pollFails(checks)
        clock.time += 1
        checks.checkAgainOnNextFailure()
        #expect(checks.findings[drive.id] != nil)
        await pollFails(checks)
        #expect(server.asks.count == 2)
    }

    @Test func aDriveThatConnectsHasNothingToExplain() async {
        let checks = makeChecks()
        await pollFails(checks)
        checks.keep(only: [])
        #expect(checks.findings.isEmpty)
    }
}

/// The service step against listeners on this device's loopback, never a real server.
@Suite struct ServiceAnswerTests {
    @Test func anSSHGreetingIsRead() async throws {
        let server = try Loopback(greeting: Data("SSH-2.0-OpenSSH_9.9\r\n".utf8))
        defer { server.stop() }
        let port = try #require(await server.start())
        #expect(await ConnectionCheck.sshAnswer(address: "127.0.0.1", port: port, limit: .seconds(3)) == .ssh)
    }

    @Test func aGreetingThatIsntSSHIsSaid() async throws {
        let server = try Loopback(greeting: Data("HTTP/1.1 400 Bad Request\r\n\r\n".utf8))
        defer { server.stop() }
        let port = try #require(await server.start())
        #expect(await ConnectionCheck.sshAnswer(address: "127.0.0.1", port: port, limit: .seconds(3)) == .notSSH)
    }

    @Test func aServiceThatSaysNothingIsSilent() async throws {
        let server = try Loopback(greeting: nil)
        defer { server.stop() }
        let port = try #require(await server.start())
        #expect(await ConnectionCheck.sshAnswer(address: "127.0.0.1", port: port, limit: .seconds(2)) == .silent)
    }

    @Test func aPortThatIsntTLSIsntHTTPS() async throws {
        let server = try Loopback(greeting: Data("HTTP/1.1 400 Bad Request\r\n\r\n".utf8))
        defer { server.stop() }
        let port = try #require(await server.start())
        let (answer, expiry) = await ConnectionCheck.tlsAnswer(
            address: "127.0.0.1", host: "localhost", port: port, limit: .seconds(3))
        #expect(answer == .notTLS)
        #expect(expiry == nil)
    }
}

/// A TCP listener on 127.0.0.1 only, which says its greeting to each connection, or nothing.
private final class Loopback: Sendable {
    private let listener: NWListener
    private let accepted = Mutex<[NWConnection]>([])
    private static let queue = DispatchQueue(label: "cloudaccess.test.loopback")

    init(greeting: Data?) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            self?.keep(connection)
            connection.start(queue: Loopback.queue)
            if let greeting {
                connection.send(content: greeting, completion: .contentProcessed { _ in })
            }
        }
    }

    private func keep(_ connection: NWConnection) {
        accepted.withLock { $0.append(connection) }
    }

    /// Starts listening, and gives the port it got.
    func start() async -> Int? {
        let resumed = Resumed()
        let listener = listener
        return await withCheckedContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumed.first() { continuation.resume(returning: listener.port.map { Int($0.rawValue) }) }
                case .failed, .cancelled:
                    if resumed.first() { continuation.resume(returning: nil) }
                default:
                    break
                }
            }
            listener.start(queue: Loopback.queue)
        }
    }

    func stop() {
        listener.cancel()
        accepted.withLock { connections in
            connections.forEach { $0.cancel() }
        }
    }
}

/// True the first time only.
private final class Resumed: Sendable {
    private let done = Mutex(false)

    func first() -> Bool {
        done.withLock { done in
            defer { done = true }
            return !done
        }
    }
}
