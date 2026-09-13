import Foundation

/// The demo world's daemon: the same `ChillDaemonProtocol` the XPC proxy
/// speaks, in-process, never chilld and never the SMC. Two fans with the
/// envelope shape of a real Apple Silicon Mac, a scripted die trace, an
/// Apple curve it plays when it holds the fans, the contract's presence
/// rule, a boost that ends by itself, and a reference cloud it records
/// exactly as chilld does: every sample taken while it holds the fans as
/// Apple. No vetoes fire: there is no sleep and no thermal
/// pressure to read. One serial queue is the actor: every verb evaluates
/// on it and replies from it, so the reply reflects the state after the
/// intent change. `@unchecked Sendable` because `queue` is the
/// confinement: every stored property is read and written on it alone.
public final class FakeDaemon: NSObject, ChillDaemonProtocol, @unchecked Sendable {
    public static let fans = [
        Fan(index: 0, min: 2317, max: 7826), Fan(index: 1, min: 2317, max: 7826),
    ]
    /// A three-minute breath: the hottest die from 42 to 82 C and back.
    public static func trace(at seconds: Double) -> Double {
        62 - 20 * cos(seconds * 2 * .pi / 180)
    }
    /// The die count the trace stands for: a 14-die chip, as status says.
    public static let dieSensors = 14
    /// Apple's curve as the demo plays it: idle to 60 C, max at 100 C.
    public static func apple(at celsius: Double, for fan: Fan) -> Double {
        fan.clamp(fan.min + (fan.max - fan.min) * (celsius - 60) / 40)
    }
    static let slewPerSecond: Double = 300

    private struct Bin: Hashable {
        let c: Int
        let rpm: Int
    }

    private let queue = DispatchQueue(label: "garden.untitled.chill.demo")
    private let clock = ContinuousClock()
    private let started: ContinuousClock.Instant
    private var ticked: ContinuousClock.Instant
    private var intent: Intent = .system
    /// The one client's declared role, from `hello`; the watcher's name.
    private var role = "?"
    private var watcher: (name: String, deadline: ContinuousClock.Instant)?
    private var actual: [Double]
    private var reason: Reason = .apple
    /// Per fan, the samples taken while Apple held it, since start.
    private var clouds: [[Bin: Int]]

    public override init() {
        started = clock.now
        ticked = started
        actual = FakeDaemon.fans.map(\.min)
        clouds = FakeDaemon.fans.map { _ in [:] }
        super.init()
    }

    // MARK: - the protocol

    public func hello(
        clientVersion: String, role: String, reply: @escaping @Sendable (Data) -> Void
    ) {
        queue.async {
            self.role = role
            reply(
                Wire.encode(
                    Reply<Hello>.ok(
                        Hello(
                            daemonVersion: Wire.version, protocolVersion: Wire.protocolVersion,
                            pid: getpid(), fans: FakeDaemon.fans))))
        }
    }

    public func use(curve: Data, reply: @escaping @Sendable (Data) -> Void) {
        queue.async {
            let decoded: Curve
            do {
                decoded = try Wire.decode(Curve.self, from: curve)
            } catch {
                reply(Wire.encode(Reply<State>.refused(.badCurve("\(error)"))))
                return
            }
            self.intent = .curve(decoded)
            reply(Wire.encode(Reply<State>.ok(self.evaluate())))
        }
    }

    public func boost(minutes: Int, reply: @escaping @Sendable (Data) -> Void) {
        queue.async {
            guard minutes > 0 else {
                reply(
                    Wire.encode(
                        Reply<State>.refused(
                            .unavailable("boost: minutes must be positive, got \(minutes)"))))
                return
            }
            self.intent = .boost(until: Date.now.addingTimeInterval(Double(minutes) * 60))
            reply(Wire.encode(Reply<State>.ok(self.evaluate())))
        }
    }

    public func system(reply: @escaping @Sendable (Data) -> Void) {
        queue.async {
            self.intent = .system
            reply(Wire.encode(Reply<State>.ok(self.evaluate())))
        }
    }

    public func presence(reply: @escaping @Sendable (Data) -> Void) {
        queue.async {
            self.claim()
            reply(Wire.encode(Reply<State>.ok(self.evaluate())))
        }
    }

    public func state(reply: @escaping @Sendable (Data) -> Void) {
        queue.async { reply(Wire.encode(Reply<State>.ok(self.evaluate()))) }
    }

    public func take(reply: @escaping @Sendable (Data) -> Void) {
        presence(reply: reply)
    }

    // MARK: - the world

    /// The one client is this process; heldBy never happens in the demo.
    /// Only `presence` and `take` claim, as in chilld: `use` and `boost`
    /// set intent and leave the watching to whoever watches.
    private func claim() {
        watcher = (role, clock.now + Wire.presenceWindow)
    }

    private func evaluate() -> State {
        let now = clock.now
        let elapsed = (now - ticked).seconds
        ticked = now
        let die = FakeDaemon.trace(at: (now - started).seconds)
        if case .boost(let until) = intent, until <= Date.now { intent = .system }
        if let current = watcher, current.deadline <= now { watcher = nil }
        let forced = intent != .system && watcher != nil
        var fans: [FanState] = []
        for fan in FakeDaemon.fans {
            let target: Double
            switch intent {
            case .curve(let curve) where forced: target = curve.target(at: die, for: fan)
            case .boost where forced: target = fan.max
            default: target = FakeDaemon.apple(at: die, for: fan)
            }
            let step = FakeDaemon.slewPerSecond * elapsed
            let current = actual[fan.index]
            actual[fan.index] = current + max(-step, min(step, target - current))
            if !forced {
                let bin = Bin(
                    c: Int(die.rounded(.down)),
                    rpm: Int(actual[fan.index]) / Cloud.rpmBin * Cloud.rpmBin)
                clouds[fan.index][bin, default: 0] += 1
            }
            fans.append(
                FanState(
                    index: fan.index, actual: actual[fan.index].rounded(), target: target.rounded(),
                    mode: forced ? 1 : 3))
        }
        let holder: Holder
        switch intent {
        case .curve(let curve) where forced: holder = .chill(curve: curve.name)
        case .boost where forced: holder = .chill(curve: "boost")
        default: holder = .apple
        }
        switch intent {
        case .system: reason = .apple
        case .curve(let curve): reason = forced ? .curve(curve.name) : .noOneWatching
        case .boost: reason = forced ? .boost : .noOneWatching
        }
        return State(
            intent: intent, holder: holder, vetoes: [],
            presence: watcher.map {
                Presence(
                    pid: getpid(), name: $0.name, secondsLeft: max(0, ($0.deadline - now).seconds))
            },
            fans: fans, die: die, dieSensors: FakeDaemon.dieSensors, dieSource: "cpu",
            lastReason: reason.description,
            clouds: FakeDaemon.fans.map { fan in
                Cloud(
                    fan: fan.index,
                    bins: clouds[fan.index]
                        .map { [$0.key.c, $0.key.rpm, $0.value] }
                        .sorted { ($0[0], $0[1]) < ($1[0], $1[1]) })
            })
    }
}
