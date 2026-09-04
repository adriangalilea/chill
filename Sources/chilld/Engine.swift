import ChillKit
import Foundation
import MachSensors

/// The one client watching, keyed by the pid of its XPC connection. The
/// listener's code-signing requirement has already proved the peer is
/// chill's own signed code; the pid is only the KEY that tells two such
/// clients apart (the app and a `--watch` CLI) and the handle the
/// invalidation handler drops. That is why `NSXPCConnection.processIdentifier`
/// is enough and the audit token is never read. The deadline is a
/// `ContinuousClock` instant: it keeps counting through sleep, so a
/// watcher from before a long sleep is gone at wake.
struct Watcher: Sendable {
    let pid: Int32
    let name: String
    let deadline: ContinuousClock.Instant
}

/// The peer of one XPC message.
struct Peer: Sendable {
    let pid: Int32
    let name: String
}

/// Why the fans are where they are, in the words `chill status` prints
/// after the intent. Derived from the read-back on every evaluation and
/// logged when it changes.
enum Reason: CustomStringConvertible, Equatable {
    case apple
    case foreign
    case vetoed(Veto)
    case noOneWatching
    case acquiring
    case curve(String)
    case boost(Double)
    case noFans

    var description: String {
        switch self {
        case .apple: return "Apple's curve"
        case .foreign: return "forced by someone else · `chill system` reclaims"
        case .vetoed(let veto): return "vetoed: \(veto.spelled) · Apple holds the fans"
        case .noOneWatching: return "no one watching → Apple holds the fans"
        case .acquiring: return "acquiring"
        case .curve(let name): return "curve \"\(name)\""
        case .boost(let rpm): return "\(Int(rpm)) rpm"
        case .noFans: return "this Mac has no fans"
        }
    }
}

extension Veto {
    /// Status order: the veto named first is the one that explains the most.
    static let order: [Veto] = [.lid, .sleep, .thermal, .noReading]

    var spelled: String {
        switch self {
        case .lid: return "lid closed"
        case .sleep: return "sleep"
        case .thermal: return "thermal pressure"
        case .noReading: return "no reading"
        }
    }
}

/// The contract, evaluated once a second: a fan is forced iff intent is
/// not system AND a watcher spoke within the window AND no veto is set.
/// Everything the daemon knows lives here, on one actor: the intent (and
/// its file), the watcher, the latched veto set, which fans chill put in
/// mode 1, the reference clouds and the last sample. `State` is built
/// from the read-back of the last evaluation, never from the last write.
actor Engine {
    /// How long the thermal state must stay at `.fair` or below before the
    /// thermal veto lifts; without it the veto oscillates with the load.
    static let thermalCalm: Duration = .seconds(30)
    /// Samples without a die temperature before `noReading` latches.
    static let missesBeforeVeto = 3
    static let period: Duration = .seconds(1)

    private struct Sample {
        var fans: [FanState] = []
        var die: Double?
        var holder: Holder = .apple
    }

    private let writer: SMCWriter
    private let hid: Result<HIDSensors, Error>
    private let clock = ContinuousClock()

    private var intent: Intent
    private var watcher: Watcher?
    private var vetoes: Set<Veto> = []
    private var thermal: ProcessInfo.ThermalState
    private var thermalCalmSince: ContinuousClock.Instant?
    private var misses = 0
    /// `kIOMessageSystemHasPoweredOn` arrived while the sleep veto is set;
    /// the next watcher message lifts it. A dark wake sends none.
    private var wokeSinceSleep = false
    /// Fans chill put in mode 1 and has not handed back. What separates
    /// "chill holds it" from `foreign` when the read-back says mode 1.
    private var held: Set<Int> = []
    private var clouds: [Int: Histogram]
    private var sample = Sample()
    private var reason: Reason = .apple
    private var inFlight: Task<Void, Never>?
    private var thermalObserver: NSObjectProtocol?

    init(writer: SMCWriter, hid: Result<HIDSensors, Error>, intent: Intent) {
        self.writer = writer
        self.hid = hid
        self.intent = intent
        // Read before observing: the notification only arrives for a
        // process that has read the state once (the documented contract).
        thermal = ProcessInfo.processInfo.thermalState
        clouds = Dictionary(
            uniqueKeysWithValues: writer.fans.map { ($0.index, Histogram(fan: $0.index)) })
        if case .failure(let error) = hid {
            Log.error("hid: \(error); no die temperature, the noReading veto will hold")
        }
    }

    // MARK: - life

    /// Latch the initial lid state, watch thermal pressure, run the loop.
    func start(lidClosed: Bool?) {
        if let lidClosed { lid(closed: lidClosed) }
        Log.notice("thermal: \(thermal.spelled)")
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: nil
        ) { _ in
            let now = ProcessInfo.processInfo.thermalState
            Task { await self.thermal(now) }
        }
        Task {
            while true {
                await evaluate()
                try? await clock.sleep(for: Engine.period)
            }
        }
    }

    /// Every fan back to Apple, on the way out of this process.
    func shutdown(_ why: String) async {
        Log.notice("\(why): handing the fans back")
        await handBack()
    }

    // MARK: - verbs

    func use(_ data: Data, from peer: Peer) async -> Reply<State> {
        let curve: Curve
        do {
            curve = try Wire.decode(Curve.self, from: data)
        } catch {
            return .refused(.badCurve("\(error)"))
        }
        if let refusal = claim(peer) { return .refused(refusal) }
        transition(to: .curve(curve), by: peer)
        await evaluate()
        return .ok(render())
    }

    func boost(minutes: Int, from peer: Peer) async -> Reply<State> {
        guard minutes > 0 else {
            return .refused(.unavailable("boost: minutes must be positive, got \(minutes)"))
        }
        if let refusal = claim(peer) { return .refused(refusal) }
        transition(to: .boost(until: Date.now.addingTimeInterval(Double(minutes) * 60)), by: peer)
        await evaluate()
        return .ok(render())
    }

    /// Intent = Apple's curve, and the fans handed back NOW, including one
    /// someone else forced: this is the verb that reclaims `foreign`.
    func system(from peer: Peer) async -> Reply<State> {
        transition(to: .system, by: peer)
        await handBack()
        await evaluate()
        return .ok(render())
    }

    func presence(from peer: Peer) -> Reply<State> {
        if let refusal = claim(peer) { return .refused(refusal) }
        return .ok(render())
    }

    func state() -> Reply<State> { .ok(render()) }

    /// Become the watcher over whoever holds it.
    func take(from peer: Peer) async -> Reply<State> {
        if let other = watcher, other.pid != peer.pid {
            Log.notice(
                "presence: \(peer.name) (pid \(peer.pid)) takes over \(other.name) (pid \(other.pid))"
            )
        }
        watcher = nil
        _ = claim(peer)
        await evaluate()
        return .ok(render())
    }

    /// The client's connection died: its presence goes with it, and the
    /// fans go back on this evaluation, not the next tick.
    func disconnected(pid: Int32) async {
        guard let current = watcher, current.pid == pid else { return }
        Log.notice("presence: \(current.name) (pid \(pid)) disconnected")
        watcher = nil
        await evaluate()
    }

    // MARK: - vetoes

    func lid(closed: Bool) {
        set(.lid, closed)
    }

    /// `kIOMessageSystemWillSleep`: the fans go back BEFORE the caller
    /// acknowledges the sleep, and the veto holds until a watcher speaks
    /// after `kIOMessageSystemHasPoweredOn`.
    func willSleep() async {
        set(.sleep, true)
        wokeSinceSleep = false
        await handBack()
    }

    func poweredOn(lidClosed: Bool?) {
        Log.notice("power: system has powered on")
        wokeSinceSleep = vetoes.contains(.sleep)
        if let lidClosed { lid(closed: lidClosed) }
    }

    func thermal(_ state: ProcessInfo.ThermalState) {
        guard state != thermal else { return }
        Log.notice("thermal: \(thermal.spelled) -> \(state.spelled)")
        thermal = state
    }

    private func set(_ veto: Veto, _ on: Bool) {
        guard vetoes.contains(veto) != on else { return }
        if on {
            vetoes.insert(veto)
            Log.notice("veto \(veto.rawValue): set (\(veto.spelled))")
        } else {
            vetoes.remove(veto)
            Log.notice("veto \(veto.rawValue): lifted")
        }
    }

    // MARK: - presence and intent

    /// Renew `peer` as the watcher, or refuse because another live client
    /// holds it. A watcher's message after a wake lifts the sleep veto.
    private func claim(_ peer: Peer) -> Refusal? {
        let now = clock.now
        if let other = watcher, other.pid != peer.pid, other.deadline > now {
            return .heldBy(pid: other.pid, name: other.name)
        }
        if watcher?.pid != peer.pid {
            Log.notice("presence: \(peer.name) (pid \(peer.pid)) watching")
        }
        watcher = Watcher(pid: peer.pid, name: peer.name, deadline: now + Wire.presenceWindow)
        if wokeSinceSleep {
            wokeSinceSleep = false
            set(.sleep, false)
        }
        return nil
    }

    private func transition(to next: Intent, by peer: Peer) {
        Log.notice("intent: \(intent) -> \(next), by \(peer.name) (pid \(peer.pid))")
        intent = next
        Policy.save(intent)
    }

    /// Every fan chill holds back to Apple; `foreign` ones too, since auto
    /// is the same write. Errors are logged, never fatal: the next
    /// evaluation reads the truth back.
    private func handBack() async {
        do {
            try await writer.reconcile()
        } catch {
            Log.error("hand back: \(error)")
        }
        held = []
    }

    // MARK: - the evaluator

    /// One pass, serialized: a caller that arrives while a pass is in
    /// flight waits for it and then runs its own, so a verb's reply always
    /// reflects a read-back taken after its intent change.
    func evaluate() async {
        while let running = inFlight {
            await running.value
            if inFlight == running { inFlight = nil }
        }
        let pass = Task { await step() }
        inFlight = pass
        await pass.value
        if inFlight == pass { inFlight = nil }
    }

    private func step() async {
        let now = clock.now
        let die = readDie()
        misses = die == nil ? misses + 1 : 0
        set(.noReading, misses >= Engine.missesBeforeVeto)
        applyThermal(now)
        if case .boost(let until) = intent, until <= Date.now {
            Log.notice("intent: \(intent) ended -> system")
            intent = .system
            Policy.save(intent)
        }
        if let current = watcher, current.deadline <= now {
            Log.notice(
                "presence: \(current.name) (pid \(current.pid)) silent for \(Wire.presenceWindow.seconds) s"
            )
            watcher = nil
        }
        let forced = intent != .system && watcher != nil && vetoes.isEmpty
        let ftst = await readFtst()
        var fans: [FanState] = []
        var holders: [Holder] = []
        for fan in writer.fans {
            do {
                let (state, holder) = try await govern(fan, forced: forced, die: die, ftst: ftst)
                fans.append(state)
                holders.append(holder)
                if let die, state.mode == 0 || state.mode == 3 {
                    clouds[fan.index]!.add(celsius: die, rpm: state.actual)
                }
            } catch {
                Log.error("fan \(fan.index): \(error)")
            }
        }
        sample = Sample(fans: fans, die: die, holder: Engine.aggregate(holders))
        let next = currentReason(forced: forced)
        if next != reason {
            Log.notice("\(intent) · \(next)")
            reason = next
        }
    }

    /// One fan: read it back, then act on what it says.
    private func govern(_ fan: Fan, forced: Bool, die: Double?, ftst: UInt8?) async throws
        -> (FanState, Holder)
    {
        let n = fan.index
        let state = try await writer.read(fan: n)
        if forced {
            guard state.mode == 1 else {
                if await !writer.isAcquiring(fan: n) {
                    Log.notice("fan \(n): mode \(state.mode), acquiring")
                    await writer.beginAcquire(fan: n)
                }
                return (state, .acquiring)
            }
            held.insert(n)
            if let die { try await writer.target(fan: n, rpm: wanted(fan, die: die)) }
            return (state, .chill(curve: intentName))
        }
        let forcedByAnyone = state.mode == 1 || ftst == 1
        let acquiring = await writer.isAcquiring(fan: n)
        if forcedByAnyone && (held.contains(n) || acquiring) {
            try await writer.auto(fan: n)
            held.remove(n)
            let after = try await writer.read(fan: n)
            return (after, after.mode == 1 ? .foreign : .apple)
        }
        held.remove(n)
        return (state, forcedByAnyone ? .foreign : .apple)
    }

    private func wanted(_ fan: Fan, die: Double) -> Double {
        switch intent {
        case .curve(let curve): return curve.target(at: die, for: fan)
        case .boost: return fan.max
        case .system: preconditionFailure("wanted() with intent system")
        }
    }

    private var intentName: String {
        switch intent {
        case .curve(let curve): return curve.name
        case .boost: return "boost"
        case .system: preconditionFailure("intentName with intent system")
        }
    }

    private func currentReason(forced: Bool) -> Reason {
        if writer.fans.isEmpty { return .noFans }
        switch intent {
        case .system:
            return sample.holder == .foreign ? .foreign : .apple
        case .curve, .boost:
            if let veto = Veto.order.first(where: vetoes.contains) { return .vetoed(veto) }
            if watcher == nil { return .noOneWatching }
            switch sample.holder {
            case .foreign: return .foreign
            case .apple, .acquiring: return .acquiring
            case .chill:
                if case .curve(let curve) = intent { return .curve(curve.name) }
                return .boost(writer.fans.map(\.max).max()!)
            }
        }
    }

    /// One holder for the status line: a fan still being taken names the
    /// whole set `acquiring`; a fan someone else forced names it `foreign`.
    private static func aggregate(_ holders: [Holder]) -> Holder {
        if holders.contains(.acquiring) { return .acquiring }
        if holders.contains(.foreign) { return .foreign }
        return holders.first { if case .chill = $0 { return true } else { return false } } ?? .apple
    }

    private func applyThermal(_ now: ContinuousClock.Instant) {
        if thermal.rawValue >= ProcessInfo.ThermalState.serious.rawValue {
            thermalCalmSince = nil
            set(.thermal, true)
        } else if vetoes.contains(.thermal) {
            let since = thermalCalmSince ?? now
            thermalCalmSince = since
            if now - since >= Engine.thermalCalm {
                thermalCalmSince = nil
                set(.thermal, false)
            }
        }
    }

    private func readDie() -> Double? {
        guard case .success(let sensors) = hid else { return nil }
        return sensors.hottest()?.celsius
    }

    private func readFtst() async -> UInt8? {
        guard writer.hasFtst else { return nil }
        do {
            return try await writer.ftst()
        } catch {
            Log.error("Ftst: \(error)")
            return nil
        }
    }

    // MARK: - state

    private func render() -> State {
        let now = clock.now
        return State(
            intent: intent,
            holder: sample.holder,
            vetoes: Veto.order.filter(vetoes.contains),
            presence: watcher.map {
                Presence(
                    pid: $0.pid, name: $0.name, secondsLeft: max(0, ($0.deadline - now).seconds))
            },
            fans: sample.fans,
            die: sample.die,
            lastReason: reason.description,
            clouds: clouds.keys.sorted().map { clouds[$0]!.render() })
    }
}

extension ProcessInfo.ThermalState {
    fileprivate var spelled: String {
        switch self {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "level \(rawValue)"
        }
    }
}
