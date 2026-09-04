import Foundation

/// The contract every process shares: the mach service, the protocol
/// version, and the codec every payload crosses the wire in.
public enum Wire {
    /// Bumped on any change to `ChillDaemonProtocol` or a payload. A
    /// client whose version differs from the daemon's makes the daemon
    /// log `upgrade: old -> new` and exit 0; KeepAlive relaunches the new
    /// image and its first act is auto.
    public static let protocolVersion = 1
    /// The launchd label, the mach service and the plist name are ONE
    /// string: `launchd/garden.untitled.chilld.plist` advertises it and
    /// `SMAppService.daemon(plistName:)` registers it.
    public static let machService = "garden.untitled.chilld"
    public static let plistName = "garden.untitled.chilld.plist"
    /// Where launchd sends the daemon's stdout and stderr, per the plist's
    /// StandardOutPath/StandardErrorPath; `chill log` reads it.
    public static let logFile = "/Library/Logs/chill/chilld.log"
    /// A client that has not spoken within this window is gone; the daemon
    /// hands the fans back to Apple on the next evaluation.
    public static let presenceWindow: Duration = .seconds(10)
    /// This image's version as the bundle stamps it, "dev" for a bare
    /// build. `hello` carries the client's, the daemon compares its own.
    public static let version =
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"

    /// Payloads cross XPC as JSON `Data`, not as `NSSecureCoding` objects:
    /// the payloads are Swift value types, and NSSecureCoding wants an
    /// NSObject subclass with a hand-written coder for every one of them,
    /// which is a second copy of every field waiting to drift. `Data` is
    /// the one class the interface whitelists; the shape is enforced by
    /// `Codable` on both ends, and `State` encoded this way IS the
    /// `status --json` document.
    public static func encode<T: Encodable>(_ value: T, pretty: Bool = false) -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = pretty ? [.sortedKeys, .prettyPrinted] : [.sortedKeys]
        return try! encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }
}

/// The daemon's verbs. Every reply block carries one `Wire.encode`d
/// `Reply<...>`: `Reply<Hello>` for `hello`, `Reply<State>` for the rest.
@objc public protocol ChillDaemonProtocol {
    /// First message on every connection: versions and the fan envelopes.
    func hello(clientVersion: String, reply: @escaping (Data) -> Void)
    /// Intent = this curve (a `Wire.encode`d `Curve`). Needs presence.
    func use(curve: Data, reply: @escaping (Data) -> Void)
    /// Intent = max rpm for `minutes`, self-ending in the daemon. Needs presence.
    func boost(minutes: Int, reply: @escaping (Data) -> Void)
    /// Intent = Apple's curve.
    func system(reply: @escaping (Data) -> Void)
    /// "I am still watching": renews the caller's presence window.
    func presence(reply: @escaping (Data) -> Void)
    /// Who holds the fans and why, without touching anything.
    func state(reply: @escaping (Data) -> Void)
    /// Become the presence holder over another client.
    func take(reply: @escaping (Data) -> Void)
}

/// Every verb answers with one of these: the payload, or why not.
public enum Reply<Payload: Codable & Sendable>: Codable, Sendable {
    case ok(Payload)
    case refused(Refusal)
}

/// The daemon's reasons for saying no; each renders as a status line.
public enum Refusal: Error, Codable, Sendable, Hashable, CustomStringConvertible {
    /// Another client holds presence; `take` overrides it.
    case heldBy(pid: Int32, name: String)
    /// The curve did not validate (`CurveError` text).
    case badCurve(String)
    /// The verb cannot be served on this Mac or in this daemon state.
    case unavailable(String)

    public var description: String {
        switch self {
        case .heldBy(let pid, let name):
            return "held by \(name) (pid \(pid)), `chill take` overrides"
        case .badCurve(let reason): return "bad curve: \(reason)"
        case .unavailable(let reason): return reason
        }
    }
}

/// One fan as `hello` ships it: index and the envelope thermalmonitord
/// reports (read once at daemon start, never live).
public struct Fan: Codable, Sendable, Hashable {
    public let index: Int
    public let min: Double
    public let max: Double

    public init(index: Int, min: Double, max: Double) {
        precondition(
            min > 0 && min < max, "fan \(index) envelope \(min)..\(max) is not positive and ordered"
        )
        self.index = index
        self.min = min
        self.max = max
    }

    public func clamp(_ rpm: Double) -> Double { Swift.min(Swift.max(rpm, min), max) }
}

public struct Hello: Codable, Sendable {
    public let daemonVersion: String
    public let protocolVersion: Int
    /// The daemon's pid, what `chill daemon status` reports.
    public let pid: Int32
    /// Empty on a Mac without fans.
    public let fans: [Fan]
    public let hasLid: Bool

    public init(daemonVersion: String, protocolVersion: Int, pid: Int32, fans: [Fan], hasLid: Bool)
    {
        self.daemonVersion = daemonVersion
        self.protocolVersion = protocolVersion
        self.pid = pid
        self.fans = fans
        self.hasLid = hasLid
    }
}

/// What the daemon was asked to do; persisted in policy.json.
public enum Intent: Codable, Sendable, Hashable, CustomStringConvertible {
    case system
    case curve(Curve)
    case boost(until: Date)

    public var description: String {
        switch self {
        case .system: return "system"
        case .curve(let curve): return "curve \"\(curve.name)\""
        case .boost(let until): return "boost until \(until.formatted(.iso8601))"
        }
    }
}

/// Apple's curve, observed: every (celsius, rpm) sample taken while Apple
/// held a fan (mode 0 or 3), binned 1 C x `rpmBin` rpm. Each entry is
/// `[celsius, rpm, count]` with celsius and rpm the bin floors. The daemon
/// accumulates it in memory and ships it in every `State`; the app is the
/// one that persists it (`~/.local/state/chill/cloud/<fan>.json`), so
/// nothing running as root ever writes into a home directory.
public struct Cloud: Codable, Sendable, Hashable {
    public static let rpmBin = 50
    public static let maxBins = 5000

    public let fan: Int
    public let bins: [[Int]]

    public init(fan: Int, bins: [[Int]]) {
        self.fan = fan
        self.bins = bins
    }
}

/// Who holds a fan, READ BACK from the mode key, never inferred from the
/// last write: mode 0 or 3 = apple; mode 1 with chill's intent = chill;
/// mode 1 without it = foreign; acquire in flight = acquiring.
public enum Holder: Codable, Sendable, Hashable {
    case apple
    case chill(curve: String)
    case acquiring
    case foreign
}

/// The daemon's own nets, latched: while any is set, presence is
/// acknowledged but not applied.
public enum Veto: String, Codable, Sendable, Hashable {
    case lid
    case sleep
    case thermal
    case noReading
}

/// The one client currently watching, keyed by its audit-token pid.
public struct Presence: Codable, Sendable, Hashable {
    public let pid: Int32
    public let name: String
    /// Seconds until the window closes without another message.
    public let secondsLeft: Double

    public init(pid: Int32, name: String, secondsLeft: Double) {
        self.pid = pid
        self.name = name
        self.secondsLeft = secondsLeft
    }
}

/// One fan as the last sample read it.
public struct FanState: Codable, Sendable, Hashable {
    public let index: Int
    public let actual: Double
    public let target: Double
    public let mode: UInt8

    public init(index: Int, actual: Double, target: Double, mode: UInt8) {
        self.index = index
        self.actual = actual
        self.target = target
        self.mode = mode
    }
}

/// The whole truth in one document: `chill status --json` prints it as is.
public struct State: Codable, Sendable {
    public let intent: Intent
    public let holder: Holder
    public let vetoes: [Veto]
    public let presence: Presence?
    public let fans: [FanState]
    /// The hottest die, nil while no sensor answers.
    public let die: Double?
    /// Why the last transition happened, as the log recorded it.
    public let lastReason: String
    /// The reference clouds, one per fan, in fan order.
    public let clouds: [Cloud]
    public let protocolVersion: Int

    public init(
        intent: Intent, holder: Holder, vetoes: [Veto], presence: Presence?, fans: [FanState],
        die: Double?, lastReason: String, clouds: [Cloud]
    ) {
        self.intent = intent
        self.holder = holder
        self.vetoes = vetoes
        self.presence = presence
        self.fans = fans
        self.die = die
        self.lastReason = lastReason
        self.clouds = clouds
        self.protocolVersion = Wire.protocolVersion
    }
}
