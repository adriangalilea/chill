import ChillKit
import Foundation
import MachSensors
import Synchronization

// chilld: the root LaunchDaemon and the ONLY SMC writer. launchd starts it
// at boot and on demand for the mach service in
// launchd/garden.untitled.chilld.plist; `KeepAlive { Crashed }` restarts a
// signal death within ThrottleInterval 1 s, so a crash loop still writes
// auto every second, while a deliberate exit (a refusal, the upgrade
// step-aside) waits for the next client message to respawn it. This file
// is the process: open the log, log the start, open the SMC, reconcile,
// load the policy, run the loop, arm the nets, listen, and hand the fans
// back on every exit that runs code.

/// The daemon's version, the bundle's stamp (`Wire.version`).
let daemonVersion = Wire.version

enum BundleError: Error, CustomStringConvertible {
    case unreadable(path: String, Error)
    case noVersion(path: String)

    var description: String {
        switch self {
        case .unreadable(let path, let error): return "bundle: cannot read \(path): \(error)"
        case .noVersion(let path): return "bundle: \(path) carries no CFBundleShortVersionString"
        }
    }
}

/// The version the bundle on disk carries NOW, read fresh from its
/// Info.plist: after an upgrade it differs from this image's, and that
/// difference, not a client's word, is what makes the daemon step aside.
/// chilld only ever runs from the registered bundle, so a plist that
/// cannot be read there is a broken install and throws.
func installedVersion() throws -> String {
    let plist = Bundle.main.bundleURL.appendingPathComponent("Contents/Info.plist")
    let info: Any
    do {
        info = try PropertyListSerialization.propertyList(
            from: try Data(contentsOf: plist), format: nil)
    } catch {
        throw BundleError.unreadable(path: plist.path, error)
    }
    guard let version = (info as? [String: Any])?["CFBundleShortVersionString"] as? String else {
        throw BundleError.noVersion(path: plist.path)
    }
    return version
}

/// A refusal at start: the daemon cannot do its job, so it says why on
/// both logs and exits 1. launchd records the exit; the next client
/// message respawns it on demand, and a Mac that can never run chilld
/// idles instead of looping.
func refuse(_ error: Error) -> Never {
    Log.fault("\(error)")
    fputs("chilld: \(error)\n", stderr)
    exit(1)
}

/// One accepted connection: its process, its token, the role `hello`
/// declared, and the chain that keeps its verbs in the order XPC delivered
/// them. Connection state is keyed by the CONNECTION, never by the pid:
/// one process can hold two connections for a moment (the app rebuilds its
/// client after a watchdog timeout while the old one drains its reply),
/// and the old one's death must not erase the new one's role or presence.
final class Session: NSObject, ChillDaemonProtocol, Sendable {
    let pid: Int32
    /// Minted at accept, unique for the daemon's life; what the engine
    /// keys the watcher by.
    let token: Int
    private let engine: Engine
    private let fans: [Fan]
    private let hasLid: Bool
    private let role = Mutex<String?>(nil)
    /// NSXPCConnection delivers a connection's messages in order on its
    /// queue; a free Task per message would run them on the pool in any
    /// order, and a burst of `use` (a held arrow key) could leave the
    /// daemon on the curve before last. Every verb, and the disconnect,
    /// awaits the one before it. `state` stays outside: it changes nothing.
    private let chain = Mutex<Task<Void, Never>?>(nil)

    init(pid: Int32, token: Int, engine: Engine, fans: [Fan], hasLid: Bool) {
        self.pid = pid
        self.token = token
        self.engine = engine
        self.fans = fans
        self.hasLid = hasLid
    }

    // MARK: - verbs

    func hello(clientVersion: String, role: String, reply: @escaping @Sendable (Data) -> Void) {
        guard clientVersion == daemonVersion else {
            let onDisk: String
            do {
                onDisk = try installedVersion()
            } catch {
                Log.error("upgrade check: \(error)")
                reply(
                    Wire.encode(
                        Reply<Hello>.refused(
                            .unavailable("chilld cannot read its bundle: \(error)"))))
                return
            }
            guard onDisk != daemonVersion else {
                // This image IS the bundle on disk: the client is the
                // stale one, and it gets told, not obeyed.
                Log.notice(
                    "hello from \(role) (pid \(pid)) \(clientVersion) refused: this bundle is \(daemonVersion)"
                )
                reply(
                    Wire.encode(
                        Reply<Hello>.refused(.stale(client: clientVersion, daemon: daemonVersion))
                    ))
                return
            }
            // A newer bundle is on disk: step aside. The client's retry
            // launches that image through the mach service, and its first
            // act is auto.
            Log.notice(
                "upgrade: \(daemonVersion) -> \(onDisk), asked by \(role) (pid \(pid)) \(clientVersion)"
            )
            reply(Wire.encode(Reply<Hello>.refused(.upgrading(from: daemonVersion, to: onDisk))))
            Task { [engine] in
                await engine.shutdown("upgrade")
                exit(0)
            }
            return
        }
        self.role.withLock { $0 = role }
        Log.notice("hello from \(role) (pid \(pid)) \(clientVersion)")
        reply(
            Wire.encode(
                Reply<Hello>.ok(
                    Hello(
                        daemonVersion: daemonVersion, protocolVersion: Wire.protocolVersion,
                        pid: getpid(), fans: fans, hasLid: hasLid))))
    }

    func use(curve: Data, reply: @escaping @Sendable (Data) -> Void) {
        serve(reply) { await $0.use(curve, from: $1) }
    }

    func boost(minutes: Int, reply: @escaping @Sendable (Data) -> Void) {
        serve(reply) { await $0.boost(minutes: minutes, from: $1) }
    }

    func system(reply: @escaping @Sendable (Data) -> Void) {
        serve(reply) { await $0.system(from: $1) }
    }

    func presence(reply: @escaping @Sendable (Data) -> Void) {
        serve(reply) { await $0.presence(from: $1) }
    }

    func state(reply: @escaping @Sendable (Data) -> Void) {
        Task { [engine] in reply(Wire.encode(await engine.state())) }
    }

    func take(reply: @escaping @Sendable (Data) -> Void) {
        serve(reply) { await $0.take(from: $1) }
    }

    /// The connection died: the presence it claimed goes, behind the verbs
    /// it already sent, so a `presence` in flight cannot land after it.
    func closed() {
        let engine = engine
        let token = token
        chained { await engine.disconnected(session: token) }
    }

    /// A verb on the engine, tagged with the peer of the message: this
    /// connection's pid and token, its name the role it declared in
    /// `hello`. A verb before `hello` has no name and is refused.
    private func serve(
        _ reply: @escaping @Sendable (Data) -> Void,
        _ verb: @escaping @Sendable (Engine, Peer) async -> Reply<State>
    ) {
        guard let role = role.withLock({ $0 }) else {
            reply(
                Wire.encode(
                    Reply<State>.refused(.unavailable("pid \(pid) spoke before hello"))))
            return
        }
        let peer = Peer(pid: pid, session: token, name: role)
        let engine = engine
        chained { reply(Wire.encode(await verb(engine, peer))) }
    }

    private func chained(_ job: @escaping @Sendable () async -> Void) {
        chain.withLock { last in
            let before = last
            last = Task {
                await before?.value
                await job()
            }
        }
    }
}

/// The listener: one `Session` per accepted connection, the signal exits,
/// and the run loop.
final class Daemon: NSObject, NSXPCListenerDelegate {
    private let listener: NSXPCListener
    private let engine: Engine
    private let fans: [Fan]
    private let hasLid: Bool
    private let queue: DispatchQueue
    private var signals: [DispatchSourceSignal] = []
    /// The session tokens, minted on the listener's queue.
    private var accepted = 0

    init(requirement: String, engine: Engine, fans: [Fan], hasLid: Bool, queue: DispatchQueue) {
        self.engine = engine
        self.fans = fans
        self.hasLid = hasLid
        self.queue = queue
        listener = NSXPCListener(machServiceName: Wire.machService)
        super.init()
        listener.setConnectionCodeSigningRequirement(requirement)
        listener.delegate = self
    }

    func run() -> Never {
        // SIGTERM (launchd's stop) and SIGINT (a terminal) are exits that
        // run code: hand the fans back, then go.
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: queue)
            source.setEventHandler { [engine] in
                blocking { await engine.shutdown("signal \(sig)") }
                exit(0)
            }
            source.resume()
            signals.append(source)
        }
        listener.resume()
        Log.notice("chilld \(daemonVersion) listening on \(Wire.machService)")
        dispatchMain()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection)
        -> Bool
    {
        accepted += 1
        let session = Session(
            pid: connection.processIdentifier, token: accepted, engine: engine, fans: fans,
            hasLid: hasLid)
        connection.exportedInterface = NSXPCInterface(with: ChillDaemonProtocol.self)
        connection.exportedObject = session
        let drop: @Sendable () -> Void = { session.closed() }
        connection.invalidationHandler = drop
        connection.interruptionHandler = drop
        connection.resume()
        Log.notice("client pid \(session.pid) connected, session \(session.token)")
        return true
    }
}

do {
    try Log.open()
} catch {
    refuse(error)
}
Log.notice("chilld \(daemonVersion) starting, pid \(getpid())")
let requirement: String
let writer: SMCWriter
let engine: Engine
let power: PowerWatch
let queue = DispatchQueue(label: "garden.untitled.chilld.events")
do {
    // An unsigned chilld cannot tell its clients apart from anyone: refuse
    // to listen at all. The install task signs.
    requirement = try requirementString()
    writer = try SMCWriter()
    // The first act, before any client can speak: every fan back to Apple,
    // `Ftst` cleared, read back. This is what makes a crash survivable. A
    // fan that will not leave mode 1 is someone else's: logged, read back
    // as `foreign` by every pass, reclaimed by `chill system`; never a
    // reason not to listen.
    do {
        try blocking { try await writer.reconcile() }
    } catch WriterError.reconcile(let failures) {
        Log.error("reconcile at start: \(WriterError.reconcile(failures)); those fans read foreign")
    }
    engine = Engine(writer: writer, hid: Result { try HIDSensors() }, intent: Policy.load())
    power = try PowerWatch(engine: engine)
    blocking { await engine.start() }
    try power.start(on: queue)
    // The lid is latched ON the callback queue, after the notification is
    // armed: every clamshell delivery is serialized behind this block, so
    // a change after the read lands after the latch, never under it.
    queue.sync {
        if let closed = power.lidClosed {
            blocking { await engine.lid(closed: closed) }
        }
    }
} catch {
    refuse(error)
}
Log.notice("peer requirement: \(requirement)")
Daemon(
    requirement: requirement, engine: engine, fans: writer.fans, hasLid: power.hasLid, queue: queue
).run()
