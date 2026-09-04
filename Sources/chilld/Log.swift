import Foundation
import os

/// The daemon's two logs behind one call. `os_log` under
/// `garden.untitled.chilld`, every interpolation `.public` (only fan and
/// temperature numbers exist here), and a timestamped line on stdout,
/// which launchd redirects to /Library/Logs/chill/chilld.log per the
/// plist: `chill log` tails that file, so no second file writer exists.
enum Log {
    static let os = Logger(subsystem: "garden.untitled.chilld", category: "chilld")

    static func notice(_ message: String) {
        os.notice("\(message, privacy: .public)")
        line(message)
    }

    static func error(_ message: String) {
        os.error("\(message, privacy: .public)")
        line("error: \(message)")
    }

    static func fault(_ message: String) {
        os.fault("\(message, privacy: .public)")
        line("fault: \(message)")
    }

    /// stdout is a file under launchd, hence fully buffered: flush so a
    /// transition is on disk before the next SMC call, crash or not.
    private static func line(_ message: String) {
        print("\(Date.now.formatted(.iso8601)) \(message)")
        fflush(stdout)
    }
}
