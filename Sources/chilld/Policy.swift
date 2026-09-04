import ChillKit
import Foundation

/// The intent that survives reboot and login:
/// `/Library/Application Support/chill/policy.json`, shaped
/// `{ intent: "system" | "curve" | "boost", curve?, boostUntil? }`. Read
/// once at start, written atomically on every intent change. Presence and
/// the vetoes are never persisted: a fresh daemon has no watcher, so the
/// persisted intent waits for one.
enum Policy {
    static let directory = URL(fileURLWithPath: "/Library/Application Support/chill")
    static let file = directory.appendingPathComponent("policy.json")

    /// No file is the first run, intent system. A file that does not parse
    /// is logged as an error and treated the same: Apple in charge is the
    /// only safe reading of a policy nobody can read.
    static func load() -> Intent {
        guard FileManager.default.fileExists(atPath: file.path) else {
            Log.notice("policy: no \(file.path), intent system")
            return .system
        }
        do {
            let intent = try Wire.decode(Document.self, from: Data(contentsOf: file)).intent
            Log.notice("policy: \(intent)")
            return intent
        } catch {
            Log.error("policy: \(file.path) does not parse (\(error)), intent system")
            return .system
        }
    }

    static func save(_ intent: Intent) {
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            try Wire.encode(Document(intent: intent)).write(to: file, options: .atomic)
            Log.notice("policy: wrote \(intent)")
        } catch {
            Log.error("policy: cannot write \(file.path): \(error)")
        }
    }

    /// The on-disk shape. `Intent`'s own Codable form is Swift's enum
    /// encoding; the file spells the three fields out so a human can read
    /// and hand-edit it.
    private struct Document: Codable {
        let intent: Intent

        private enum Keys: String, CodingKey {
            case intent
            case curve
            case boostUntil
        }

        init(intent: Intent) { self.intent = intent }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            switch try c.decode(String.self, forKey: .intent) {
            case "system": intent = .system
            case "curve": intent = .curve(try c.decode(Curve.self, forKey: .curve))
            case "boost": intent = .boost(until: try c.decode(Date.self, forKey: .boostUntil))
            case let other:
                throw DecodingError.dataCorruptedError(
                    forKey: .intent, in: c, debugDescription: "unknown intent \"\(other)\"")
            }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: Keys.self)
            switch intent {
            case .system:
                try c.encode("system", forKey: .intent)
            case .curve(let curve):
                try c.encode("curve", forKey: .intent)
                try c.encode(curve, forKey: .curve)
            case .boost(let until):
                try c.encode("boost", forKey: .intent)
                try c.encode(until, forKey: .boostUntil)
            }
        }
    }
}
