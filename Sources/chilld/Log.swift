import ChillKit
import Foundation
import os

enum LogError: Error, CustomStringConvertible {
    case open(path: String, errno: Int32)

    var description: String {
        switch self {
        case .open(let path, let code):
            return "log: cannot open \(path): \(String(cString: strerror(code)))"
        }
    }
}

/// The daemon's two logs behind one call. `os_log` under
/// `garden.untitled.chilld`, every interpolation `.public` (only fan and
/// temperature numbers exist here), and a timestamped line on stdout,
/// which `open` points at `Wire.logFile`: `chill log` tails that file, so
/// no second file writer exists.
enum Log {
    static let os = Logger(subsystem: "garden.untitled.chilld", category: "chilld")

    /// chilld owns its log file. launchd opens the plist's StandardOutPath
    /// before exec and creates no parent directory, so on a fresh Mac that
    /// open fails and every line would be lost: the daemon's first act
    /// makes the directory and points fds 1 and 2 at the file, appending.
    /// The plist keeps the same path, so launchd's own pre-exec messages
    /// land in the file once the directory exists.
    static func open() throws {
        let directory = (Wire.logFile as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true)
        let fd = Foundation.open(Wire.logFile, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { throw LogError.open(path: Wire.logFile, errno: errno) }
        for target in [STDOUT_FILENO, STDERR_FILENO] {
            guard dup2(fd, target) == target else {
                throw LogError.open(path: Wire.logFile, errno: errno)
            }
        }
        close(fd)
    }

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

    /// stdout is a file, hence fully buffered: flush so a transition is on
    /// disk before the next SMC call, crash or not.
    private static func line(_ message: String) {
        print("\(Date.now.formatted(.iso8601)) \(message)")
        fflush(stdout)
    }
}
