import ChillKit
import Foundation

/// `~/.local/state/chill/config.json`: what the app remembers between
/// launches and the daemon has no business knowing. `lastCurve` is the
/// canvas's first cursor; `push` is the one knob that shapes the built-in
/// `chill` curve, the one most people never leave.
struct Config: Codable, Equatable {
    var lastCurve: String?
    /// How hard chill pushes, 0 to 1: at 0 the fans sit at their minimum
    /// until 65 °C and climb gently; as it rises the floor comes up, the
    /// climb starts earlier and gets steeper; at 1 the curve is the
    /// ceiling, every fan flat out.
    var push: Double = Config.defaultPush
    /// The dot on the tab the toggle would press, and its tip: shown
    /// until "got it", then never.
    var keyHintDismissed = false
    /// chill has met a live daemon on this Mac. The first time it does, with
    /// the daemon still on Apple's curve, chill starts the `chill` curve:
    /// installing chill is asking for it, and a fresh install that left the
    /// fans to Apple read as broken. Never again after: from then on what
    /// runs is what the person chose.
    var started: Bool

    static let defaultPush = 0.0

    init(lastCurve: String?, started: Bool) {
        self.lastCurve = lastCurve
        self.started = started
    }

    /// Fields read their first-run value when the file predates them.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lastCurve = try c.decodeIfPresent(String.self, forKey: .lastCurve)
        push = try c.decodeIfPresent(Double.self, forKey: .push) ?? Config.defaultPush
        keyHintDismissed = try c.decodeIfPresent(Bool.self, forKey: .keyHintDismissed) ?? false
        // A file from before the field is a Mac that already chose.
        started = try c.decodeIfPresent(Bool.self, forKey: .started) ?? true
    }

    /// The file, or the first-run value (the demo world starts on its
    /// seed curve, already chosen). A file that does not parse is an error,
    /// not a reset: the app wrote it, the app can read it.
    static func load(_ demo: Demo) throws -> Config {
        guard FileManager.default.fileExists(atPath: demo.config.path) else {
            return Config(lastCurve: demo.on ? Demo.seedLastCurve : nil, started: demo.on)
        }
        return try Wire.decode(Config.self, from: Data(contentsOf: demo.config))
    }

    func save(_ demo: Demo) throws {
        try FileManager.default.createDirectory(at: demo.state, withIntermediateDirectories: true)
        try Wire.encode(self, pretty: true).write(to: demo.config, options: .atomic)
    }
}
