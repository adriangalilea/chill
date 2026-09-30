import AppKit
import ChillKit
import Foundation

/// The menu bar and the canvas, what `chill` with no argument runs (Finder,
/// the login item). An accessory app: no dock icon, a status item, the
/// canvas on demand. In the demo world every content-bearing root is the
/// `-demo` sibling and the daemon is `FakeDaemon` through the same
/// `Client`; the canvas opens at once, since the demo exists to be seen.
/// `shot` is the demo's still: the popover with your curve running, written
/// as a PNG by the app itself, then the process exits.
enum App {
    @MainActor static func run(demo: Demo, shot: URL? = nil) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = Delegate(demo: demo, shot: shot)
        app.delegate = delegate
        app.run()
        fatalError("NSApplication.run returned")
    }
}

@MainActor
final class Delegate: NSObject, NSApplicationDelegate {
    let demo: Demo
    let shot: URL?
    private var model: Model!
    private var menuBar: MenuBar!
    private var pulse: Pulse!
    private var signals: [DispatchSourceSignal] = []

    init(demo: Demo, shot: URL?) {
        precondition(shot == nil || demo.on, "a still is taken in the demo world only")
        self.demo = demo
        self.shot = shot
    }

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
        if let shot {
            take(shot)
        } else if demo.on {
            model.openCanvas()
        }
    }

    /// The link needs a moment to go live before `use` lands, and the plot
    /// a while longer: the curve's morph, the die's breath, the afterglow
    /// the live point leaves. Then the popover's own window is captured,
    /// shadow off, and the app quits. A capture that writes nothing is
    /// fatal: the likely cause is Screen Recording, not granted to the
    /// terminal that launched this.
    private func take(_ shot: URL) {
        model.shooting = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [self] in
            guard let curve = model.yourCurve else { Verbs.die("shot: no curve to run") }
            model.use(curve)
            menuBar.open()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [self] in
            guard let window = model.popover?.contentViewController?.view.window else {
                Verbs.die("shot: the popover has no window")
            }
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), shot.path]
            do { try capture.run() } catch { Verbs.die("shot: \(error)") }
            capture.waitUntilExit()
            guard capture.terminationStatus == 0, FileManager.default.fileExists(atPath: shot.path)
            else {
                Verbs.die(
                    "shot: screencapture wrote nothing (exit \(capture.terminationStatus)); grant Screen Recording to the terminal"
                )
            }
            print("shot: \(shot.path)")
            NSApp.terminate(nil)
        }
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
