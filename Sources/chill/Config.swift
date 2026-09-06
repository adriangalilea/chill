import ChillKit
import Foundation

/// `~/.local/state/chill/config.json`: what the app remembers between
/// launches and the daemon has no business knowing. `lastCurve` is the
/// canvas's first cursor; `push` is the one knob that shapes the built-in
/// `calm` curve, the one most people never leave.
struct Config: Codable, Equatable {
    var lastCurve: String?
    /// How hard calm pushes, 0 to 1: at 0 the fans sit at their minimum
    /// until 65 °C and climb gently; as it rises the floor comes up, the
    /// climb starts earlier and gets steeper; at 1 the curve is the
    /// ceiling, every fan flat out.
    var push: Double = Config.defaultPush

    static let defaultPush = 0.0

    init(lastCurve: String?) { self.lastCurve = lastCurve }

    /// The knob reads its first-run value when the file predates it.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lastCurve = try c.decodeIfPresent(String.self, forKey: .lastCurve)
        push = try c.decodeIfPresent(Double.self, forKey: .push) ?? Config.defaultPush
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
