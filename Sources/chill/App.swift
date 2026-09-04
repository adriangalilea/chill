import ChillKit
import Foundation
import Ink
import Keymap

/// The menu bar and the canvas: Ink + Keymap, an `ActionID` registry, `?`
/// shows the bindings. Sends intent and presence at 1 Hz, renders the
/// daemon's state, reads sensors through the read-only package for the
/// canvas and never writes the SMC. `demo` forks every content-bearing
/// root to `~/.local/state/chill-demo` and talks to an in-process
/// conformer of `ChillDaemonProtocol` instead of chilld.
enum App {
    static func run(demo: Bool) -> Never {
        print("app: stage 5\(demo ? " (demo)" : "")")
        exit(0)
    }
}
