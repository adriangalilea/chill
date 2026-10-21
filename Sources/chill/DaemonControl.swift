import AppInstallations
import ChillKit
import Foundation

/// `chill daemon install|uninstall|status`: chilld is the app's job
/// (AppInstallations, `AppInstallation.Job.chilld`), so `mise run install`,
/// the popover's "install chilld" and a human land the same registration
/// for the same image.
enum DaemonControl {
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

    private static let job = AppInstallation.Job.chilld

    /// Installed and answering (registered, approved, Login Items opened
    /// once when the approval is pending, a minute for it), then a fanless
    /// Mac refused, then the login item so presence returns at login.
    static func install() {
        print(
            "installing chilld; if Login Items opens, an admin approves it once: \(AppInstallation.Job.approvalSteer)"
        )
        do {
            _ = try blocking { try await job.install(approvalWait: .seconds(60)) }
        } catch AppInstallation.Job.Failure.awaitingApproval {
            Verbs.die(
                "chilld still awaits approval: \(AppInstallation.Job.approvalSteer) Then rerun.")
        } catch {
            Verbs.die("install chilld: \(error)")
        }
        let client = Verbs.connect(Demo(on: false), role: .cli)
        let hello = greet(client)
        if hello.fans.isEmpty {
            try? job.uninstall()
            Verbs.die("this Mac has no fans; chilld unregistered")
        }
        do {
            _ = try blocking { try await AppInstallation.Job.loginItem.install() }
        } catch {
            Verbs.die("register the login item: \(error)")
        }
        print(
            "daemon: running · chilld \(hello.daemonVersion) · pid \(hello.pid) · \(hello.fans.count) fans · login item registered"
        )
    }

    /// Apple's curve first, over XPC and read back, said here; then the
    /// registrations (the job hands the fans back again on its own way out,
    /// since unregistering sends no SIGTERM).
    static func uninstall() {
        if job.state(probing: false) == .running {
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
            print("daemon: \(job.words)")
        }
        do {
            try AppInstallation.Job.loginItem.uninstall()
            try job.uninstall()
        } catch {
            Verbs.die("uninstall: \(error)")
        }
        print("daemon: unregistered")
    }

    /// The job's state, then the round trip that proves the signature check
    /// passes in both directions.
    static func status() {
        print("daemon: \(job.words)")
        let requirement: String
        do {
            requirement = try requirementString()
        } catch {
            print("signature: \(error)")
            exit(1)
        }
        guard job.state(probing: false) == .running else { exit(1) }
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
}
