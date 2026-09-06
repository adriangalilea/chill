import AppKit
import ChillKit
import CoreGraphics

/// The contract's second leg, from the app: presence at 1 Hz while this
/// session is on the console and the screens are awake. Off the console
/// (fast user switching, an ssh launch) or with the screens asleep the
/// pulse still runs, but sends `state()` instead: the glyph stays
/// truthful and no one is claimed to be watching. A dark wake gets no
/// presence this way, which is what lifts the sleep veto only for a
/// person.
@MainActor
final class Pulse {
    private let model: Model
    private var timer: Timer?
    private var screensAwake = true
    private var observers: [NSObjectProtocol] = []

    init(model: Model) {
        self.model = model
        let center = NSWorkspace.shared.notificationCenter
        observers.append(
            center.addObserver(
                forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.screensAwake = false }
            })
        observers.append(
            center.addObserver(
                forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.screensAwake = true }
            })
        // Common modes: the status menu and a live resize run the loop in
        // event tracking, where a default-mode timer never fires, and a
        // menu held open past the presence window would hand the fans
        // back mid-look.
        let timer = Timer(timeInterval: Wire.pulsePeriod.seconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    private func tick() {
        let watching = screensAwake && Pulse.onConsole
        Task { await model.pulse(watching: watching) }
    }

    /// Whether this login session owns the console right now; no session
    /// dictionary at all (a launch from ssh) is not on it.
    static var onConsole: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return false
        }
        return session[kCGSessionOnConsoleKey as String] as? Bool ?? false
    }
}
