import ChillKit
import Foundation
import MachSensors

// chilld: the root LaunchDaemon and the ONLY SMC writer. launchd starts it
// for the mach service in launchd/garden.untitled.chilld.plist, KeepAlive
// restarts it, ThrottleInterval 1 keeps a crash loop writing auto every
// second. This file is the process: log the start, open the SMC,
// reconcile, load the policy, arm the nets, run the loop, listen, and hand
// the fans back on every exit that runs code.

/// The daemon's version, the bundle's stamp (`Wire.version`).
let daemonVersion = Wire.version

/// The XPC face of the engine: one object owns the listener and turns
/// every verb into an engine call, tagged with the peer of the message.
final class Daemon: NSObject, NSXPCListenerDelegate, ChillDaemonProtocol {
    private let listener: NSXPCListener
    private let engine: Engine
    private let writer: SMCWriter
    private let power: PowerWatch
    private let queue: DispatchQueue
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
        let drop: () -> Void = { Task { await engine.disconnected(pid: pid) } }
        connection.invalidationHandler = drop
        connection.interruptionHandler = drop
        connection.resume()
        Log.notice("client pid \(pid) connected")
        return true
    }

    // MARK: - verbs

    func hello(clientVersion: String, reply: @escaping (Data) -> Void) {
        let peer = Peer.current()
        guard clientVersion == daemonVersion else {
            // A newer bundle is on disk and its client is speaking: step
            // aside so KeepAlive launches the new image, whose first act
            // is auto. The client retries after the relaunch.
            Log.notice("upgrade: \(daemonVersion) -> \(clientVersion), asked by \(peer.name)")
            reply(
                Wire.encode(
                    Reply<Hello>.refused(
                        .unavailable(
                            "chilld \(daemonVersion) is stepping aside for \(clientVersion), retry"
                        ))))
            Task { [engine] in
                await engine.shutdown("upgrade")
                exit(0)
            }
            return
        }
        Log.notice("hello from \(peer.name) (pid \(peer.pid)) \(clientVersion)")
        reply(
            Wire.encode(
                Reply<Hello>.ok(
                    Hello(
                        daemonVersion: daemonVersion, protocolVersion: Wire.protocolVersion,
                        pid: getpid(), fans: writer.fans, hasLid: power.hasLid))))
    }

    func use(curve: Data, reply: @escaping (Data) -> Void) {
        let peer = Peer.current()
        Task { [engine] in reply(Wire.encode(await engine.use(curve, from: peer))) }
    }

    func boost(minutes: Int, reply: @escaping (Data) -> Void) {
        let peer = Peer.current()
        Task { [engine] in reply(Wire.encode(await engine.boost(minutes: minutes, from: peer))) }
    }

    func system(reply: @escaping (Data) -> Void) {
        let peer = Peer.current()
        Task { [engine] in reply(Wire.encode(await engine.system(from: peer))) }
    }

    func presence(reply: @escaping (Data) -> Void) {
        let peer = Peer.current()
        Task { [engine] in reply(Wire.encode(await engine.presence(from: peer))) }
    }

    func state(reply: @escaping (Data) -> Void) {
        Task { [engine] in reply(Wire.encode(await engine.state())) }
    }

    func take(reply: @escaping (Data) -> Void) {
        let peer = Peer.current()
        Task { [engine] in reply(Wire.encode(await engine.take(from: peer))) }
    }
}

extension Peer {
    /// The peer of the message being handled: its pid from the connection
    /// and its process name from the kernel, read on the XPC thread before
    /// any hop.
    static func current() -> Peer {
        let pid = NSXPCConnection.current()!.processIdentifier
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        return Peer(pid: pid, name: length > 0 ? String(cString: buffer) : "pid \(pid)")
    }
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
    try power.start(on: queue)
    blocking { await engine.start(lidClosed: power.lidClosed) }
} catch {
    refuse(error)
}
Log.notice("peer requirement: \(requirement)")
Daemon(requirement: requirement, engine: engine, writer: writer, power: power, queue: queue).run()
