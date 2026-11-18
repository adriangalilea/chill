import Foundation

/// The demo world's daemon: the same `ChillDaemonProtocol` the XPC proxy
/// speaks, in-process, never chilld and never the SMC. Two fans with the
/// envelope shape of a real Apple Silicon Mac, a scripted die trace that
/// its curves follow as heat (`Heat.follow`, as chilld does), an Apple
/// curve it plays when it holds the fans, the contract's presence rule and
/// a boost that ends by itself. No vetoes fire: there is no sleep and no thermal
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
    /// Where Apple's curve wakes the fans: a MacBook keeps them off until
    /// the chip is hot, the value chill is for.
    public static let appleWakes = 90.0
    /// Apple's curve as the demo plays it, the way a MacBook runs it: off
    /// below `appleWakes`, then from the floor toward the ceiling at 120 C.
    public static func apple(at celsius: Double, for fan: Fan) -> Double {
        celsius < appleWakes
            ? 0 : fan.clamp(fan.min + (fan.max - fan.min) * (celsius - appleWakes) / 30)
    }
    /// How fast a fan's rpm moves: an Apple Silicon fan spins from its
    /// floor to its ceiling in about four seconds.
    static let slewPerSecond: Double = 1500

    // The demo's physics, one set for every clock that steps it: this
    // daemon on the wall clock, the app's film on its own.

    /// Where a fan heads at this heat: the curve's rpm while chill holds the
    /// fans (the maximum for a boost), Apple's curve otherwise.
    public static func target(_ fan: Fan, heat: Double, intent: Intent, forced: Bool) -> Double {
        switch intent {
        case .curve(let curve) where forced: return curve.target(at: heat, for: fan)
        case .boost where forced: return fan.max
        default: return apple(at: heat, for: fan)
        }
    }

    /// A fan's rpm after `seconds`, slewing toward its target.
    public static func slew(_ actual: Double, toward target: Double, seconds: Double) -> Double {
        let step = slewPerSecond * seconds
        return actual + max(-step, min(step, target - actual))
    }

    public static func holder(_ intent: Intent, forced: Bool) -> Holder {
        switch intent {
        case .curve(let curve) where forced: return .chill(curve: curve.name)
        case .boost where forced: return .chill(curve: "boost")
        default: return .apple
        }
    }

    public static func reason(_ intent: Intent, forced: Bool) -> Reason {
        switch intent {
        case .system: return .apple
        case .curve(let curve): return forced ? .curve(curve.name) : .noOneWatching
        case .boost: return forced ? .boost : .noOneWatching
        }
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
    private var heat: Double?

    public override init() {
        started = clock.now
        ticked = started
        actual = FakeDaemon.fans.map { FakeDaemon.apple(at: FakeDaemon.trace(at: 0), for: $0) }
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

    /// The demo world has no real stop to hand back for: the state as it is.
    public func handBack(reply: @escaping @Sendable (Data) -> Void) {
        queue.async { reply(Wire.encode(Reply<State>.ok(self.evaluate()))) }
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
        let heat = Heat.follow(self.heat, die: die, seconds: elapsed)
        self.heat = heat
        if case .boost(let until) = intent, until <= Date.now { intent = .system }
        if let current = watcher, current.deadline <= now { watcher = nil }
        let forced = intent != .system && watcher != nil
        var fans: [FanState] = []
        for fan in FakeDaemon.fans {
            let target = FakeDaemon.target(fan, heat: heat, intent: intent, forced: forced)
            actual[fan.index] = FakeDaemon.slew(
                actual[fan.index], toward: target, seconds: elapsed)
            fans.append(
                FanState(
                    index: fan.index, actual: actual[fan.index].rounded(), target: target.rounded(),
                    mode: forced ? 1 : 3))
        }
        let holder = FakeDaemon.holder(intent, forced: forced)
        reason = FakeDaemon.reason(intent, forced: forced)
        return State(
            intent: intent, holder: holder, vetoes: [],
            presence: watcher.map {
                Presence(
                    pid: getpid(), name: $0.name, secondsLeft: max(0, ($0.deadline - now).seconds))
            },
            fans: fans, die: die, heat: heat, dieSensors: FakeDaemon.dieSensors,
            dieSource: "cpu", lastReason: reason.description)
    }
}
