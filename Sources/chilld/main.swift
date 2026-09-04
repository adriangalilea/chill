import ChillKit
import Foundation
import os

// chilld: the root LaunchDaemon and the ONLY SMC writer. launchd starts it
// for the mach service in launchd/garden.untitled.chilld.plist, KeepAlive
// restarts it, ThrottleInterval 1 keeps a crash loop writing auto every
// second. Everything it does, it does from `Daemon`; this file is the
// process: log the start, listen, run forever.

let log = Logger(subsystem: "garden.untitled.chill", category: "chilld")

/// The daemon's version as the bundle stamps it; "dev" for a bare build.
let daemonVersion =
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"

/// One object owns the listener and every verb. The 1 Hz evaluator
/// (intent x presence x vetoes), the SMC writer, the presence holder and
/// the veto set attach here; every verb below answers `unavailable` until
/// the loop exists, which is the truth of a daemon with no loop.
final class Daemon: NSObject, NSXPCListenerDelegate, ChillDaemonProtocol {
    private let listener: NSXPCListener

    init(requirement: String) {
        listener = NSXPCListener(machServiceName: Wire.machService)
        super.init()
        listener.setConnectionCodeSigningRequirement(requirement)
        listener.delegate = self
    }

    func run() -> Never {
        listener.resume()
        log.notice(
            "chilld \(daemonVersion, privacy: .public) listening on \(Wire.machService, privacy: .public)"
        )
        dispatchMain()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection)
        -> Bool
    {
        connection.exportedInterface = NSXPCInterface(with: ChillDaemonProtocol.self)
        connection.exportedObject = self
        connection.resume()
        log.notice("client pid \(connection.processIdentifier, privacy: .public) connected")
        return true
    }

    // MARK: - verbs

    private func notYet(_ verb: String, _ reply: (Data) -> Void) {
        log.notice("\(verb, privacy: .public): no loop yet")
        reply(Wire.encode(Reply<State>.refused(.unavailable("chilld \(daemonVersion): not yet"))))
    }

    func hello(clientVersion: String, reply: @escaping (Data) -> Void) {
        log.notice("hello from client \(clientVersion, privacy: .public)")
        reply(Wire.encode(Reply<Hello>.refused(.unavailable("chilld \(daemonVersion): not yet"))))
    }

    func use(curve: Data, reply: @escaping (Data) -> Void) { notYet("use", reply) }
    func boost(minutes: Int, reply: @escaping (Data) -> Void) { notYet("boost", reply) }
    func system(reply: @escaping (Data) -> Void) { notYet("system", reply) }
    func presence(reply: @escaping (Data) -> Void) { notYet("presence", reply) }
    func state(reply: @escaping (Data) -> Void) { notYet("state", reply) }
    func take(reply: @escaping (Data) -> Void) { notYet("take", reply) }
}

log.notice("chilld \(daemonVersion, privacy: .public) starting, pid \(getpid(), privacy: .public)")
let requirement: String
do {
    requirement = try requirementString()
} catch {
    // An unsigned chilld cannot tell its clients apart from anyone: refuse
    // to listen at all. launchd logs the exit; the install task signs.
    log.fault("\(String(describing: error), privacy: .public)")
    FileHandle.standardError.write(Data("chilld: \(error)\n".utf8))
    exit(1)
}
log.notice("peer requirement: \(requirement, privacy: .public)")
Daemon(requirement: requirement).run()
