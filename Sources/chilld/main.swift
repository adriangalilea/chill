import ChillKit
import Foundation

// chilld: the root LaunchDaemon and the ONLY SMC writer. launchd starts it
// for the mach service in launchd/garden.untitled.chilld.plist, KeepAlive
// restarts it, ThrottleInterval 1 keeps a crash loop writing auto every
// second. Everything it does, it does from `Daemon`; this file is the
// process: log the start, open the SMC, reconcile, listen, run forever.

/// The daemon's version as the bundle stamps it; "dev" for a bare build.
let daemonVersion =
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"

/// One object owns the listener, the writer and every verb. The 1 Hz
/// evaluator (intent x presence x vetoes), the presence holder and the
/// veto set attach here; every verb below answers `unavailable` until the
/// loop exists, which is the truth of a daemon with no loop.
final class Daemon: NSObject, NSXPCListenerDelegate, ChillDaemonProtocol {
    private let listener: NSXPCListener
    let writer: SMCWriter

    init(requirement: String, writer: SMCWriter) {
        self.writer = writer
        listener = NSXPCListener(machServiceName: Wire.machService)
        super.init()
        listener.setConnectionCodeSigningRequirement(requirement)
        listener.delegate = self
    }

    func run() -> Never {
        listener.resume()
        Log.notice("chilld \(daemonVersion) listening on \(Wire.machService)")
        dispatchMain()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection)
        -> Bool
    {
        connection.exportedInterface = NSXPCInterface(with: ChillDaemonProtocol.self)
        connection.exportedObject = self
        connection.resume()
        Log.notice("client pid \(connection.processIdentifier) connected")
        return true
    }

    // MARK: - verbs

    private func notYet(_ verb: String, _ reply: (Data) -> Void) {
        Log.notice("\(verb): no loop yet")
        reply(Wire.encode(Reply<State>.refused(.unavailable("chilld \(daemonVersion): not yet"))))
    }

    func hello(clientVersion: String, reply: @escaping (Data) -> Void) {
        Log.notice("hello from client \(clientVersion)")
        reply(Wire.encode(Reply<Hello>.refused(.unavailable("chilld \(daemonVersion): not yet"))))
    }

    func use(curve: Data, reply: @escaping (Data) -> Void) { notYet("use", reply) }
    func boost(minutes: Int, reply: @escaping (Data) -> Void) { notYet("boost", reply) }
    func system(reply: @escaping (Data) -> Void) { notYet("system", reply) }
    func presence(reply: @escaping (Data) -> Void) { notYet("presence", reply) }
    func state(reply: @escaping (Data) -> Void) { notYet("state", reply) }
    func take(reply: @escaping (Data) -> Void) { notYet("take", reply) }
}

/// A refusal at start: the daemon cannot do its job, so it says why on
/// both logs and exits 1. launchd records the exit; KeepAlive retries.
func refuse(_ error: Error) -> Never {
    Log.fault("\(error)")
    FileHandle.standardError.write(Data("chilld: \(error)\n".utf8))
    exit(1)
}

/// Run one async job to completion from this synchronous top level. Off
/// the main thread on purpose: the main thread is about to block in
/// `dispatchMain`, and the job's actor hops must not need it.
func blocking(_ job: @escaping @Sendable () async throws -> Void) throws {
    let done = DispatchSemaphore(value: 0)
    let outcome = OutcomeBox()
    Task.detached {
        do { try await job() } catch { outcome.error = error }
        done.signal()
    }
    done.wait()
    if let error = outcome.error { throw error }
}

final class OutcomeBox: @unchecked Sendable {
    var error: Error?
}

Log.notice("chilld \(daemonVersion) starting, pid \(getpid())")
let requirement: String
let writer: SMCWriter
do {
    // An unsigned chilld cannot tell its clients apart from anyone: refuse
    // to listen at all. The install task signs.
    requirement = try requirementString()
    writer = try SMCWriter()
    // The first act, before any client can speak: every fan back to Apple,
    // `Ftst` cleared, read back. This is what makes a crash survivable.
    try blocking { try await writer.reconcile() }
} catch {
    refuse(error)
}
Log.notice("peer requirement: \(requirement)")
Daemon(requirement: requirement, writer: writer).run()
