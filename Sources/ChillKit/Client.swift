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
    /// A reply that has not landed within this window fails THAT call as
    /// `unreachable`; the connection stays up, so the next call (a retry
    /// through a relaunch, the app's next pulse) reaches the daemon.
    public static let replyTimeout: Duration = .seconds(10)
    /// How long `hello` retries after the daemon steps aside for an
    /// upgrade: the retry's own message launches the new image on demand
    /// through the mach service, within a second.
    public static let relaunchWindow: Duration = .seconds(10)

    public nonisolated let demo: Demo
    /// What this client declares itself in `hello`; the daemon names the
    /// watcher by it.
    public nonisolated let role: Role
    /// NSXPCConnection is thread-safe; only `invalidate()` (deinit) and
    /// proxy creation touch it off the actor.
    private nonisolated(unsafe) let connection: NSXPCConnection?
    private let fake: FakeDaemon?
    private var greeted: Hello?

    /// The daemon's registration as SMAppService reports it right now.
    public static var registration: SMAppService.Status {
        SMAppService.daemon(plistName: Wire.plistName).status
    }

    /// Throws when this process cannot derive a code-signing requirement
    /// from its own signature (unsigned, ad-hoc): such a client could not
    /// tell chilld from anything else, and chilld would refuse it anyway.
    public init(demo: Demo, role: Role) throws {
        self.demo = demo
        self.role = role
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
            let role = role.rawValue
            let reply: Reply<Hello> = try await exchange("hello") { daemon, reply in
                daemon.hello(clientVersion: Wire.version, role: role, reply: reply)
            }
            switch reply {
            case .ok(let hello):
                greeted = hello
                return hello
            case .refused(.upgrading(let from, let to)):
                // The daemon is stepping aside for a newer bundle; its
                // replacement answers on the same mach service within the
                // window. Every other refusal is the answer, at once.
                guard ContinuousClock.now < deadline else {
                    throw ClientError.refused(.upgrading(from: from, to: to))
                }
                try await Task.sleep(for: .seconds(1))
            case .refused(let refusal):
                throw ClientError.refused(refusal)
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

    private typealias Send =
        @Sendable (ChillDaemonProtocol, @escaping @Sendable (Data) -> Void) ->
        Void

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

    /// The reply, the proxy's error handler and the watchdog race for one
    /// continuation; `Settle` lets exactly one of them resume it and drops
    /// the rest (a reply after the timeout, an error after the reply).
    private func transport(_ send: @escaping Send) async throws -> Data {
        if let fake {
            return await withCheckedContinuation { k in
                send(fake) { data in k.resume(returning: data) }
            }
        }
        let connection = connection!
        return try await withCheckedThrowingContinuation { k in
            let settle = Settle(k)
            let watchdog = Task {
                try await Task.sleep(for: Client.replyTimeout)
                settle.resume(
                    .failure(.unreachable("no reply in \(Client.replyTimeout.seconds) s")))
            }
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                watchdog.cancel()
                settle.resume(.failure(Client.classify(error)))
            }
            send(proxy as! ChillDaemonProtocol) { data in
                watchdog.cancel()
                settle.resume(.success(data))
            }
        }
    }

    private static func classify(_ error: Error) -> ClientError {
        switch registration {
        case .notRegistered, .notFound: return .notInstalled
        case .requiresApproval: return .awaitingApproval
        case .enabled: return .unreachable(error.localizedDescription)
        @unknown default: return .unreachable("registration status \(registration.rawValue)")
        }
    }
}

/// One continuation, resumed once: whichever of the reply, the error
/// handler and the watchdog gets here first wins, the others find it gone.
private final class Settle: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: CheckedContinuation<Data, Error>?

    init(_ k: CheckedContinuation<Data, Error>) { pending = k }

    func resume(_ outcome: Result<Data, ClientError>) {
        let k: CheckedContinuation<Data, Error>? = lock.withLock {
            defer { pending = nil }
            return pending
        }
        guard let k else { return }
        switch outcome {
        case .success(let data): k.resume(returning: data)
        case .failure(let error): k.resume(throwing: error)
        }
    }
}

extension Duration {
    /// Whole and fractional seconds, for a status line or a payload.
    public var seconds: Double {
        let (s, attos) = components
        return ((Double(s) + Double(attos) / 1e18) * 1000).rounded() / 1000
    }
}
