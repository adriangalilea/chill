import Foundation
import ServiceManagement

/// Why a verb got no answer, in the words `chill status` prints. The
/// three daemon states are read from `SMAppService` AFTER the connection
/// failed, never guessed from the failure alone: a refused connection to
/// a registered, approved daemon is `unreachable`; the same failure with
/// no registration is `notInstalled`.
public enum ClientError: Error, CustomStringConvertible {
    case notInstalled
    case awaitingApproval
    case unreachable(String)
    /// The daemon answered, and said no.
    case refused(Refusal)
    /// The daemon answered something `Reply` cannot decode: a wire
    /// mismatch the version handshake should have caught.
    case malformed(verb: String, Error)

    public var description: String {
        switch self {
        case .notInstalled: return "daemon: not installed"
        case .awaitingApproval: return "daemon: awaiting approval (\(Wire.approvalPath))"
        case .unreachable(let why): return "daemon: unreachable (\(why))"
        case .refused(let refusal): return refusal.description
        case .malformed(let verb, let error):
            return "daemon: \(verb) reply does not parse: \(error)"
        }
    }
}

/// One conversation with a daemon: chilld over XPC, or the demo's
/// in-process `FakeDaemon`, behind the same `ChillDaemonProtocol`. The
/// first message on a real connection is `hello`, once, so the version
/// handshake (and the daemon stepping aside for an upgrade) happens
/// before any verb. Synchronous helpers serve the CLI, async ones the
/// app; both are the one async core. An actor: the app's pulse and its
/// verbs share one instance from concurrent tasks, and `greeted` is
/// written by whichever `hello` lands first.
public actor Client {
    /// A daemon that has not replied within this window is wedged, not
    /// slow: the connection is invalidated so the pending call fails
    /// instead of hanging the CLI.
    public static let replyTimeout: Duration = .seconds(10)
    /// How long `hello` retries after the daemon steps aside for an
    /// upgrade (KeepAlive relaunches the new image within a second).
    public static let relaunchWindow: Duration = .seconds(10)

    public nonisolated let demo: Demo
    private let connection: NSXPCConnection?
    private let fake: FakeDaemon?
    private var greeted: Hello?

    /// The daemon's registration as SMAppService reports it right now.
    public static var registration: SMAppService.Status {
        SMAppService.daemon(plistName: Wire.plistName).status
    }

    /// Throws when this process cannot derive a code-signing requirement
    /// from its own signature (unsigned, ad-hoc): such a client could not
    /// tell chilld from anything else, and chilld would refuse it anyway.
    public init(demo: Demo) throws {
        self.demo = demo
        if demo.on {
            fake = FakeDaemon()
            connection = nil
            return
        }
        fake = nil
        let requirement = try requirementString()
        let c = NSXPCConnection(machServiceName: Wire.machService, options: .privileged)
        c.remoteObjectInterface = NSXPCInterface(with: ChillDaemonProtocol.self)
        c.setCodeSigningRequirement(requirement)
        c.resume()
        connection = c
    }

    deinit { connection?.invalidate() }

    // MARK: - verbs, async

    public func hello() async throws -> Hello {
        if let greeted { return greeted }
        let deadline = ContinuousClock.now + Client.relaunchWindow
        while true {
            let reply: Reply<Hello> = try await exchange("hello") { daemon, reply in
                daemon.hello(clientVersion: Wire.version, reply: reply)
            }
            switch reply {
            case .ok(let hello):
                greeted = hello
                return hello
            case .refused(let refusal):
                // The daemon is stepping aside for this newer image; its
                // replacement answers on the same mach service.
                guard ContinuousClock.now < deadline else { throw ClientError.refused(refusal) }
                try await Task.sleep(for: .seconds(1))
            }
        }
    }

    public func state() async throws -> State {
        try await verb("state") { $0.state(reply: $1) }
    }

    public func use(_ curve: Curve) async throws -> State {
        let data = Wire.encode(curve)
        return try await verb("use") { $0.use(curve: data, reply: $1) }
    }

    public func boost(minutes: Int) async throws -> State {
        try await verb("boost") { $0.boost(minutes: minutes, reply: $1) }
    }

    public func system() async throws -> State {
        try await verb("system") { $0.system(reply: $1) }
    }

    public func presence() async throws -> State {
        try await verb("presence") { $0.presence(reply: $1) }
    }

    public func take() async throws -> State {
        try await verb("take") { $0.take(reply: $1) }
    }

    // MARK: - verbs, synchronous (the CLI)

    public nonisolated func hello() throws -> Hello { try blocking { try await self.hello() } }
    public nonisolated func state() throws -> State { try blocking { try await self.state() } }
    public nonisolated func use(_ curve: Curve) throws -> State {
        try blocking { try await self.use(curve) }
    }
    public nonisolated func boost(minutes: Int) throws -> State {
        try blocking { try await self.boost(minutes: minutes) }
    }
    public nonisolated func system() throws -> State { try blocking { try await self.system() } }
    public nonisolated func presence() throws -> State {
        try blocking { try await self.presence() }
    }
    public nonisolated func take() throws -> State { try blocking { try await self.take() } }

    // MARK: - the core

    private typealias Send = (ChillDaemonProtocol, @escaping (Data) -> Void) -> Void

    /// hello first, then the verb; a refusal is an error to the caller.
    private func verb(_ name: String, _ send: @escaping Send) async throws -> State {
        _ = try await hello()
        let reply: Reply<State> = try await exchange(name, send)
        switch reply {
        case .ok(let state): return state
        case .refused(let refusal): throw ClientError.refused(refusal)
        }
    }

    /// One message, one reply, decoded. Transport failures are classified
    /// against the live registration status.
    private func exchange<P: Codable & Sendable>(_ name: String, _ send: @escaping Send)
        async throws -> Reply<P>
    {
        let data = try await transport(send)
        do {
            return try Wire.decode(Reply<P>.self, from: data)
        } catch {
            throw ClientError.malformed(verb: name, error)
        }
    }

    private func transport(_ send: @escaping Send) async throws -> Data {
        if let fake {
            return await withCheckedContinuation { k in
                send(fake) { data in k.resume(returning: data) }
            }
        }
        let connection = connection!
        let timedOut = Flag()
        let watchdog = Task {
            try await Task.sleep(for: Client.replyTimeout)
            timedOut.set()
            connection.invalidate()
        }
        defer { watchdog.cancel() }
        return try await withCheckedThrowingContinuation { k in
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                k.resume(throwing: Client.classify(error, timedOut: timedOut.isSet))
            }
            send(proxy as! ChillDaemonProtocol) { data in k.resume(returning: data) }
        }
    }

    private static func classify(_ error: Error, timedOut: Bool) -> ClientError {
        if timedOut {
            return .unreachable("no reply in \(Client.replyTimeout.seconds) s")
        }
        switch registration {
        case .notRegistered, .notFound: return .notInstalled
        case .requiresApproval: return .awaitingApproval
        case .enabled: return .unreachable(error.localizedDescription)
        @unknown default: return .unreachable("registration status \(registration.rawValue)")
        }
    }
}

/// Run one async job to completion from a synchronous thread that is not
/// serving the XPC replies (the CLI's main thread qualifies: replies land
/// on the connection's own queue).
private func blocking<T: Sendable>(_ job: @escaping @Sendable () async throws -> T) throws -> T {
    let done = DispatchSemaphore(value: 0)
    let box = Box<T>()
    Task.detached {
        do { box.outcome = .success(try await job()) } catch { box.outcome = .failure(error) }
        done.signal()
    }
    done.wait()
    return try box.outcome!.get()
}

private final class Box<T>: @unchecked Sendable {
    var outcome: Result<T, Error>?
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

extension Duration {
    /// Whole and fractional seconds, for a status line or a payload.
    public var seconds: Double {
        let (s, attos) = components
        return ((Double(s) + Double(attos) / 1e18) * 1000).rounded() / 1000
    }
}
