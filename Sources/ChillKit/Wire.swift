import Foundation

/// The contract every process shares: the mach service, the protocol
/// version, and the codec every payload crosses the wire in.
public enum Wire {
    /// Bumped on any change to `ChillDaemonProtocol` or a payload; shipped
    /// in `hello` and in every `State` so a mismatch is visible.
    public static let protocolVersion = 6
    /// The launchd label, the mach service and the plist name are ONE
    /// string: `launchd/garden.untitled.chilld.plist` advertises it and
    /// `SMAppService.daemon(plistName:)` registers it.
    public static let machService = "garden.untitled.chilld"
    public static let plistName = "garden.untitled.chilld.plist"
    /// The daemon's log. chilld creates the directory and reopens its
    /// stdout and stderr onto this file as its first act (launchd opens the
    /// plist's StandardOutPath before exec and makes no parent directory,
    /// so it cannot); `chill log` reads it.
    public static let logFile = "/Library/Logs/chill/chilld.log"
    /// Where a LaunchDaemon is approved, as every surface names it.
    public static let approvalPath = "System Settings › General › Login Items & Extensions"
    /// A client that has not spoken within this window is gone; the daemon
    /// hands the fans back to Apple on the next evaluation.
    public static let presenceWindow: Duration = .seconds(10)
    /// How often a watcher speaks (the app's `Pulse`, the CLI's `--watch`):
    /// three pulses fit inside `presenceWindow` with room, so one lost
    /// exchange never hands the fans back.
    public static let pulsePeriod: Duration = {
        let period: Duration = .seconds(1)
        precondition(
            period * 3 < presenceWindow, "pulse \(period) is not well inside \(presenceWindow)")
        return period
    }()
    /// How long a boost runs when no length is given: the app's `b`, the
    /// CLI's bare `chill boost`, and the usage line all read this one.
    public static let boostMinutes = 5
    /// This image's version as the bundle stamps it, "dev" for a bare
    /// build. `hello` carries the client's, the daemon compares its own.
    /// Resolved from the executable's REAL path, not `Bundle.main`: the
    /// CLI runs through the `~/.local/bin/chill` symlink, and `Bundle.main`
    /// seen through a symlink has no Info.plist.
    public static let version: String = {
        let executable = Bundle.main.executableURL!.resolvingSymlinksInPath()
        let contents = executable.deletingLastPathComponent().deletingLastPathComponent()
        let bundle = Bundle(url: contents.deletingLastPathComponent())
        return bundle?.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }()

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

/// What a client IS, declared in `hello` and worn as its watcher name: the
/// app and the CLI are one executable, so the process name cannot tell
/// them apart, and "held by chill (pid N)" would name neither.
public enum Role: String, Sendable {
    case app = "chill.app"
    case cli = "chill"
    case watch = "chill --watch"
}

/// The daemon's verbs. Every reply block carries one `Wire.encode`d
/// `Reply<...>`: `Reply<Hello>` for `hello`, `Reply<State>` for the rest.
/// Reply blocks are `@Sendable`: XPC invokes them from its own queue and
/// the daemon calls them from a task.
@objc public protocol ChillDaemonProtocol {
    /// First message on every connection: versions, the client's `Role`
    /// (its `rawValue`), and the fan envelopes back.
    func hello(clientVersion: String, role: String, reply: @escaping @Sendable (Data) -> Void)
    /// Intent = this curve (a `Wire.encode`d `Curve`). Applied only while
    /// someone watches; the caller does not become the watcher by asking.
    func use(curve: Data, reply: @escaping @Sendable (Data) -> Void)
    /// Intent = max rpm for `minutes`, self-ending in the daemon. Applied
    /// only while someone watches.
    func boost(minutes: Int, reply: @escaping @Sendable (Data) -> Void)
    /// Intent = Apple's curve.
    func system(reply: @escaping @Sendable (Data) -> Void)
    /// "I am watching": claims presence, or renews it; refused `heldBy`
    /// while another live client holds it.
    func presence(reply: @escaping @Sendable (Data) -> Void)
    /// Who holds the fans and why, without touching anything.
    func state(reply: @escaping @Sendable (Data) -> Void)
    /// Become the presence holder over another client.
    func take(reply: @escaping @Sendable (Data) -> Void)
}

/// Every verb answers with one of these: the payload, or why not.
public enum Reply<Payload: Codable & Sendable>: Codable, Sendable {
    case ok(Payload)
    case refused(Refusal)
}

/// The daemon's reasons for saying no; each renders as a status line.
public enum Refusal: Error, Codable, Sendable, Hashable, CustomStringConvertible {
    /// Another client holds presence; `take` (`--watch --take`) overrides it.
    case heldBy(pid: Int32, name: String)
    /// The curve did not validate (`CurveError` text).
    case badCurve(String)
    /// The verb cannot be served on this Mac or in this daemon state.
    case unavailable(String)
    /// The daemon is stepping aside for the newer bundle on disk; the
    /// client's retry launches that image. The one refusal worth retrying.
    case upgrading(from: String, to: String)
    /// The client is older than the installed bundle: a final answer,
    /// never retried; the process has to be relaunched from the bundle.
    case stale(client: String, daemon: String)

    public var description: String {
        switch self {
        case .heldBy(let pid, let name):
            return "held by \(name) (pid \(pid)); rerun with --watch --take to take over"
        case .badCurve(let reason): return "bad curve: \(reason)"
        case .unavailable(let reason): return reason
        case .upgrading(let from, let to):
            return "chilld \(from) is stepping aside for \(to), retry"
        case .stale(let client, let daemon):
            return
                "chill \(client) is not chilld \(daemon), the installed bundle; relaunch chill.app"
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

    public init(daemonVersion: String, protocolVersion: Int, pid: Int32, fans: [Fan]) {
        self.daemonVersion = daemonVersion
        self.protocolVersion = protocolVersion
        self.pid = pid
        self.fans = fans
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
/// acknowledged but not applied. No lid: a closed lid on a Mac that
/// stays awake is a Mac that stays awake, and one that sleeps is the
/// sleep veto.
public enum Veto: String, Codable, Sendable, Hashable {
    case sleep
    case thermal
    case noReading
}

/// The one client currently watching, named by its connection's pid
/// (`NSXPCConnection.processIdentifier`) and role; the code-signing
/// requirement on the listener is the gate, the pid only tells two of
/// chill's own clients apart. The daemon keys the watcher by the
/// connection itself, so a dead connection of the same process can never
/// drop a live one's presence.
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
    /// The temperature the curve follows, nil while no sensor answers.
    public let die: Double?
    /// How many sensors answered this sample; `die` is their max.
    public let dieSensors: Int
    /// What `die` is the max of: `cpu` or `gpu` from the SMC's named keys,
    /// `die` when only the HID path answers.
    public let dieSource: String
    /// Why the last transition happened, as the log recorded it.
    public let lastReason: String
    /// The reference clouds, one per fan, in fan order.
    public let clouds: [Cloud]
    public let protocolVersion: Int

    public init(
        intent: Intent, holder: Holder, vetoes: [Veto], presence: Presence?, fans: [FanState],
        die: Double?, dieSensors: Int, dieSource: String, lastReason: String, clouds: [Cloud]
    ) {
        self.intent = intent
        self.holder = holder
        self.vetoes = vetoes
        self.presence = presence
        self.fans = fans
        self.die = die
        self.dieSensors = dieSensors
        self.dieSource = dieSource
        self.lastReason = lastReason
        self.clouds = clouds
        self.protocolVersion = Wire.protocolVersion
    }
}
