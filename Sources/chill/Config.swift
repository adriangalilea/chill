import ChillKit
import Foundation

/// `~/.local/state/chill/config.json`: what the app remembers between
/// launches and the daemon has no business knowing. `lastCurve` is the
/// right-click toggle's target and the canvas's first cursor.
struct Config: Codable, Equatable {
    var lastCurve: String?

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
