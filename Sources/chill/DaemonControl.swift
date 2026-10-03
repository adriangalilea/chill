import ChillKit
import Foundation
import ServiceManagement

/// `chill daemon install|uninstall|status`: the binary owns its
/// registration (`SMAppService.daemon(plistName:)` + the login item), so
/// `mise run install`, the cask's postflight and a human land the same
/// registration for the same image.
enum DaemonControl {
    /// Status polls at 0.5 s; approval is a human act, so a minute.
    static let approvalPolls = 120

    static func run(_ args: [String], demo: Demo) {
        if demo.on {
            Verbs.die("the demo daemon runs in-process; nothing to \(args.first ?? "do")")
        }
        switch args.first {
        case "install": install()
        case "uninstall": uninstall()
        case "status": status()
        default: Verbs.die("usage: chill daemon install|uninstall|status")
        }
    }

    private static var daemon: SMAppService { SMAppService.daemon(plistName: Wire.plistName) }

    /// register, poll to `.enabled` (opening System Settings once when
    /// approval is needed), reach the daemon, refuse a fanless Mac, then
    /// the login item so presence returns at login.
    static func install() {
        if Placement.current != .installable { Verbs.die(Placement.current.notFound) }
        register(daemon, "chilld")
        var told = false
        poll: for _ in 0..<approvalPolls {
            switch daemon.status {
            case .enabled:
                break poll
            case .requiresApproval:
                if !told {
                    print("approve chilld under \(Wire.approvalPath) (an admin's act)")
                    SMAppService.openSystemSettingsLoginItems()
                    told = true
                }
                usleep(500_000)
            case .notRegistered, .notFound:
                Verbs.die("chilld registration vanished (\(spell(daemon.status)))")
            @unknown default:
                Verbs.die("chilld registration status \(daemon.status.rawValue)")
            }
        }
        guard daemon.status == .enabled else {
            Verbs.die(
                "chilld still awaits approval; approve it under \(Wire.approvalPath), then rerun")
        }
        let client = Verbs.connect(Demo(on: false), role: .cli)
        let hello = greet(client)
        if hello.fans.isEmpty {
            unregister(daemon, "chilld")
            Verbs.die("this Mac has no fans; chilld unregistered")
        }
        register(SMAppService.mainApp, "the login item")
        print(
            "daemon: enabled · chilld \(hello.daemonVersion) · pid \(hello.pid) · \(hello.fans.count) fans · login item registered"
        )
    }

    /// Apple's curve first, over XPC and read back, then the
    /// registrations. unregister kills a running daemon without a
    /// SIGTERM, which is why `system()` has to land before it.
    static func uninstall() {
        if daemon.status == .enabled {
            let client = Verbs.connect(Demo(on: false), role: .cli)
            do {
                let state = try client.system()
                print(Status.line(state))
                if state.holder != .apple {
                    Verbs.note("chill: the fans still read \(state.holder) after system()")
                }
            } catch {
                Verbs.note("chill: \(error); unregistering anyway")
            }
        } else {
            print("daemon: \(spell(daemon.status))")
        }
        unregister(SMAppService.mainApp, "the login item")
        unregister(daemon, "chilld")
        print("daemon: unregistered")
    }

    /// Registration, then the round trip that proves the signature check
    /// passes in both directions.
    static func status() {
        let registration = daemon.status
        print("daemon: \(spell(registration))")
        let requirement: String
        do {
            requirement = try requirementString()
        } catch {
            print("signature: \(error)")
            exit(1)
        }
        guard registration == .enabled else { exit(1) }
        do {
            let hello = try Client(demo: Demo(on: false), role: .cli).hello()
            print(
                "chilld \(hello.daemonVersion) · pid \(hello.pid) · \(hello.fans.count) fans"
            )
            print("signature: accepted · \(requirement)")
        } catch {
            print("\(error)")
            print("signature: \(requirement)")
            exit(1)
        }
    }

    // MARK: - helpers

    private static func register(_ service: SMAppService, _ what: String) {
        do {
            try service.register()
        } catch {
            guard (error as NSError).code == kSMErrorAlreadyRegistered else {
                Verbs.die("register \(what): \(error.localizedDescription)")
            }
        }
    }

    /// Idempotent: a service that is not registered is already the goal,
    /// and `unregister()` on one answers EINVAL; one SMAppService cannot
    /// find (an unsigned bundle left by a failed install) answers EPERM.
    private static func unregister(_ service: SMAppService, _ what: String) {
        if service.status == .notRegistered || service.status == .notFound { return }
        do {
            try service.unregister()
        } catch {
            guard (error as NSError).code == kSMErrorJobNotFound else {
                Verbs.die("unregister \(what): \(error.localizedDescription)")
            }
        }
    }

    /// launchd bootstraps the daemon after approval; give it the window.
    private static func greet(_ client: Client) -> Hello {
        let deadline = ContinuousClock.now + Client.relaunchWindow
        while true {
            do {
                return try client.hello()
            } catch {
                guard ContinuousClock.now < deadline else { Verbs.die("\(error)") }
                usleep(500_000)
            }
        }
    }

    static func spell(_ status: SMAppService.Status) -> String {
        switch status {
        case .enabled: return "enabled"
        case .requiresApproval: return "awaiting approval (\(Wire.approvalPath))"
        case .notRegistered: return "not installed"
        case .notFound: return Placement.current.notFound
        @unknown default: return "status \(status.rawValue)"
        }
    }
}
