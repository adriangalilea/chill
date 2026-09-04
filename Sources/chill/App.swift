import ChillKit
import Foundation
import Ink
import Keymap

/// The menu bar and the canvas: Ink + Keymap, an `ActionID` registry, `?`
/// shows the bindings. Sends intent and presence at 1 Hz, renders the
/// daemon's state, reads sensors through the read-only package for the
/// canvas and never writes the SMC. In the demo world every
/// content-bearing root is the `-demo` sibling and the daemon is
/// `FakeDaemon` through the same `Client`.
enum App {
    static func run(demo: Demo) -> Never {
        print(demo.mark("app: stage 5"))
        exit(0)
    }
}
