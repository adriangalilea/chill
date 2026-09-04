import ChillKit
import Foundation

/// The CLI verbs. Each one is one XPC conversation with chilld
/// (`NSXPCConnection(machServiceName:options: .privileged)`, the code
/// signing requirement from `requirementString()` set before `resume()`),
/// rendered as the one honest status line.
enum Client {
    static func die(_ message: String, exit code: Int32 = 1) -> Never {
        FileHandle.standardError.write(Data("chill: \(message)\n".utf8))
        exit(code)
    }

    static func notYet(_ verb: String) -> Never { die("\(verb): not yet") }

    static func status(json: Bool, demo: Bool) { notYet("status") }

    static func curve(_ args: [String], demo: Bool) {
        switch args.first {
        case "list", "show", "use": notYet("curve \(args[0])")
        default: die("usage: chill curve list|show <name>|use <name> [--watch]")
        }
    }

    static func boost(_ args: [String], demo: Bool) { notYet("boost") }

    static func system(demo: Bool) { notYet("system") }

    static func log(follow: Bool) { notYet("log") }
}

/// `chill daemon install|uninstall|status`: the binary owns its
/// registration (`SMAppService.daemon(plistName:)` + the login item), so
/// `mise run install`, the cask's postflight and a human land the same
/// registration for the same image.
enum DaemonControl {
    static func run(_ args: [String]) {
        switch args.first {
        case "install", "uninstall", "status": Client.notYet("daemon \(args[0])")
        default: Client.die("usage: chill daemon install|uninstall|status")
        }
    }
}
