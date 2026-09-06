import ChillKit
import Foundation

/// `~/.local/state/chill/config.json`: what the app remembers between
/// launches and the daemon has no business knowing. `lastCurve` is the
/// right-click toggle's target and the canvas's first cursor; `kickIn`
/// and `slope` are the two knobs that shape the built-in `chill`
/// curve, the one most people never leave.
struct Config: Codable, Equatable {
    var lastCurve: String?
    /// Apple's cloud on the plot, the `a` toggle.
    var showCloud = true
    /// The die temperature (°C) below which the built-in curve sits at
    /// the fan's minimum.
    var kickIn: Double = Config.defaultKickIn
    /// 0 = a gentle 45 °C ramp to maximum, 1 = a steep 15 °C one.
    var slope: Double = Config.defaultSlope

    static let defaultKickIn = 65.0
    static let defaultSlope = 0.5
    static let kickInRange = 45.0...90.0

    init(lastCurve: String?) { self.lastCurve = lastCurve }

    /// Both knobs read their first-run value when the file predates them.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lastCurve = try c.decodeIfPresent(String.self, forKey: .lastCurve)
        showCloud = try c.decodeIfPresent(Bool.self, forKey: .showCloud) ?? true
        kickIn = try c.decodeIfPresent(Double.self, forKey: .kickIn) ?? Config.defaultKickIn
        slope =
            try c.decodeIfPresent(Double.self, forKey: .slope) ?? Config.defaultSlope
    }

    /// The file, or the first-run value (the demo world starts on its
    /// seed curve). A file that does not parse is an error, not a reset:
    /// the app wrote it, the app can read it.
    static func load(_ demo: Demo) throws -> Config {
        guard FileManager.default.fileExists(atPath: demo.config.path) else {
            return Config(lastCurve: demo.on ? Demo.seedLastCurve : nil)
        }
        return try Wire.decode(Config.self, from: Data(contentsOf: demo.config))
    }

    func save(_ demo: Demo) throws {
        try FileManager.default.createDirectory(at: demo.state, withIntermediateDirectories: true)
        try Wire.encode(self, pretty: true).write(to: demo.config, options: .atomic)
    }
}
