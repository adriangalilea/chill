import AppKit
import ChillKit
import Foundation

/// The menu bar and the canvas, what `chill` with no argument runs (Finder,
/// the login item). An accessory app: no dock icon, a status item, the
/// canvas on demand. In the demo world every content-bearing root is the
/// `-demo` sibling and the daemon is `FakeDaemon` through the same
/// `Client`; the canvas opens at once, since the demo exists to be seen.
enum App {
    @MainActor static func run(demo: Demo) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = Delegate(demo: demo)
        app.delegate = delegate
        app.run()
        fatalError("NSApplication.run returned")
    }
}

@MainActor
final class Delegate: NSObject, NSApplicationDelegate {
    let demo: Demo
    private var model: Model!
    private var menuBar: MenuBar!
    private var pulse: Pulse!
    private var signals: [DispatchSourceSignal] = []

    init(demo: Demo) { self.demo = demo }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            model = try Model(demo: demo)
        } catch {
            // A state file that does not parse is an error, not a reset,
            // and it names its path. From Finder or the login item there
            // is no stderr, so it is said on screen before the exit.
            guard isatty(STDERR_FILENO) == 0 else { Verbs.die("\(error)") }
            let alert = NSAlert()
            alert.messageText = "chill cannot start"
            alert.informativeText = "\(error)"
            alert.runModal()
            exit(1)
        }
        menuBar = MenuBar(model: model)
        pulse = Pulse(model: model)
        model.startKeys()
        // A signal is a quit like any other: the clouds land first.
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signals.append(source)
        }
        if demo.on { model.openCanvas() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.quit()
    }

    /// A Finder double-click on the running app means "show me the canvas".
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        model.openCanvas()
        return false
    }
}
