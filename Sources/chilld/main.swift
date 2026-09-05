import ChillKit
import Foundation
import MachSensors
import Synchronization

// chilld: the root LaunchDaemon and the ONLY SMC writer. launchd starts it
// for the mach service in launchd/garden.untitled.chilld.plist, KeepAlive
// restarts it, ThrottleInterval 1 keeps a crash loop writing auto every
// second. This file is the process: open the log, log the start, open the
// SMC, reconcile, load the policy, run the loop, arm the nets, listen, and
// hand the fans back on every exit that runs code.

/// The daemon's version, the bundle's stamp (`Wire.version`).
let daemonVersion = Wire.version

/// The version the bundle on disk carries NOW, read fresh from its
/// Info.plist: after an upgrade it differs from this image's, and that
/// difference, not a client's word, is what makes the daemon step aside.
/// "dev" where there is no bundle, as `Wire.version` says of a bare build.
func installedVersion() -> String {
    let plist = Bundle.main.bundleURL.appendingPathComponent("Contents/Info.plist")
    guard let data = try? Data(contentsOf: plist),
        let info = try? PropertyListSerialization.propertyList(from: data, format: nil)
            as? [String: Any],
        let version = info["CFBundleShortVersionString"] as? String
    else { return "dev" }
    return version
}

/// Each live connection's declared `Role`, by pid: written by `hello`,
/// dropped with the connection, read to name a verb's `Peer`. Connections
/// deliver on their own queues, hence the lock.
final class Roles: Sendable {
    private let table = Mutex<[Int32: String]>([:])

    subscript(pid: Int32) -> String? { table.withLock { $0[pid] } }
    func set(_ role: String, for pid: Int32) { table.withLock { $0[pid] = role } }
    func drop(_ pid: Int32) { table.withLock { $0[pid] = nil } }
}

/// The XPC face of the engine: one object owns the listener and turns
/// every verb into an engine call, tagged with the peer of the message.
final class Daemon: NSObject, NSXPCListenerDelegate, ChillDaemonProtocol {
    private let listener: NSXPCListener
    private let engine: Engine
    private let writer: SMCWriter
    private let power: PowerWatch
    private let queue: DispatchQueue
    private let roles = Roles()
    private var signals: [DispatchSourceSignal] = []

    init(
        requirement: String, engine: Engine, writer: SMCWriter, power: PowerWatch,
        queue: DispatchQueue
    ) {
        self.engine = engine
        self.writer = writer
        self.power = power
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
        connection.exportedInterface = NSXPCInterface(with: ChillDaemonProtocol.self)
        connection.exportedObject = self
        let pid = connection.processIdentifier
        let engine = engine
        let roles = roles
        let drop: @Sendable () -> Void = {
            roles.drop(pid)
            Task { await engine.disconnected(pid: pid) }
        }
        connection.invalidationHandler = drop
        connection.interruptionHandler = drop
        connection.resume()
        Log.notice("client pid \(pid) connected")
        return true
    }

    // MARK: - verbs

    func hello(clientVersion: String, role: String, reply: @escaping @Sendable (Data) -> Void) {
        let pid = NSXPCConnection.current()!.processIdentifier
        guard clientVersion == daemonVersion else {
            let onDisk = installedVersion()
            guard onDisk != daemonVersion else {
                // This image IS the bundle on disk: the client is the
                // stale one, and it gets told, not obeyed.
                Log.notice(
                    "hello from \(role) (pid \(pid)) \(clientVersion) refused: this bundle is \(daemonVersion)"
                )
                reply(
                    Wire.encode(
                        Reply<Hello>.refused(
                            .unavailable(
                                "chill \(clientVersion) is not chilld \(daemonVersion), the installed bundle; relaunch chill.app"
                            ))))
                return
            }
            // A newer bundle is on disk: step aside so KeepAlive launches
            // its image, whose first act is auto. The client retries after
            // the relaunch.
            Log.notice(
                "upgrade: \(daemonVersion) -> \(onDisk), asked by \(role) (pid \(pid)) \(clientVersion)"
            )
            reply(
                Wire.encode(
                    Reply<Hello>.refused(
                        .unavailable(
                            "chilld \(daemonVersion) is stepping aside for \(onDisk), retry")
                    )))
            Task { [engine] in
                await engine.shutdown("upgrade")
                exit(0)
            }
            return
        }
        roles.set(role, for: pid)
        Log.notice("hello from \(role) (pid \(pid)) \(clientVersion)")
        reply(
            Wire.encode(
                Reply<Hello>.ok(
                    Hello(
                        daemonVersion: daemonVersion, protocolVersion: Wire.protocolVersion,
                        pid: getpid(), fans: writer.fans, hasLid: power.hasLid))))
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

    /// A verb on the engine, tagged with the peer of the message: its pid
    /// from the connection, its name the role that connection declared in
    /// `hello`, both read on the XPC thread before any hop. A verb before
    /// `hello` has no name and is refused.
    private func serve(
        _ reply: @escaping @Sendable (Data) -> Void,
        _ verb: @escaping @Sendable (Engine, Peer) async -> Reply<State>
    ) {
        let pid = NSXPCConnection.current()!.processIdentifier
        guard let role = roles[pid] else {
            reply(
                Wire.encode(
                    Reply<State>.refused(.unavailable("pid \(pid) spoke before hello"))))
            return
        }
        let peer = Peer(pid: pid, name: role)
        Task { [engine] in reply(Wire.encode(await verb(engine, peer))) }
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
    // `Ftst` cleared, read back. This is what makes a crash survivable.
    try blocking { try await writer.reconcile() }
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
Daemon(requirement: requirement, engine: engine, writer: writer, power: power, queue: queue).run()
