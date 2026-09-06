import ChillKit
import Foundation
import MachSensors

/// The one client watching. The listener's code-signing requirement has
/// already proved the peer is chill's own signed code; the pid only tells
/// two such clients apart (the app and a `--watch` CLI) for `heldBy` and
/// the status line, which is why `NSXPCConnection.processIdentifier` is
/// enough and the audit token is never read. `session` is the CONNECTION
/// (a token minted at accept): one process can hold two connections for a
/// moment (the app rebuilds its client after a watchdog timeout while the
/// old one drains), and only the connection that claimed the presence may
/// drop it. The deadline is a `ContinuousClock` instant: it keeps counting
/// through sleep, so a watcher from before a long sleep is gone at wake.
struct Watcher: Sendable {
    let pid: Int32
    let session: Int
    let name: String
    let deadline: ContinuousClock.Instant
}

/// The peer of one XPC message: its process, its connection, its role.
struct Peer: Sendable {
    let pid: Int32
    let session: Int
    let name: String
}

/// The contract, evaluated once a second: a fan is forced iff intent is
/// not system AND a watcher spoke within the window AND no veto is set.
/// Everything the daemon knows lives here, on one actor: the intent (and
/// its file), the watcher, the latched veto set, which fans chill put in
/// mode 1, the reference clouds and the last sample. `State` is built
/// from the read-back of the last evaluation, never from the last write.
///
/// Two things touch the SMC through this actor, a pass of the evaluator
/// and a hand-back, and they are SERIALIZED through `inFlight`: whoever
/// comes second waits for the first to finish. A pass snapshots the intent
/// once and re-reads the world after every suspension before it writes;
/// a world that moved under it (a verb, a veto, a shutdown) abandons the
/// pass, and the mover's own hand-back or evaluation runs next.
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
        var dieSensors = 0
        var dieSource = "die"
        var holder: Holder = .apple
        /// Fans whose READ threw (or whose judgment needed a `Ftst` read
        /// that threw); they are missing from `fans`.
        var unread: [Int] = []
        /// Fans chill holds whose target write the firmware refused, the
        /// read-back disagreeing with the value written; they are in
        /// `fans` with the target they really hold.
        var refused: [(fan: Int, result: UInt8)] = []
    }

    /// The world moved under a forced pass between its read and its write.
    private struct Moved: Error {}

    /// One fan's verdict from `govern`.
    private struct Governed {
        let state: FanState
        let holder: Holder
        /// This pass wrote auto on the fan, so `Ftst` may have changed
        /// under the fans still to be judged.
        let released: Bool
        /// The result byte of a target write whose read-back disagreed.
        var refused: UInt8? = nil
    }

    private let writer: SMCWriter
    /// The chip's named parts over a read-only SMC handle of its own; nil
    /// where the catalogue knows no keys for this Mac (M1/M2, or newer
    /// than the catalogue), and then the HID die is the source.
    private let parts: Parts?
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
    /// This process is on its way out: nothing is forced from here on.
    private var halting = false
    /// Fans chill wrote, or is writing, mode 1 on and has not handed back:
    /// entered the moment an acquire begins, since its success lands
    /// between passes. What separates "chill holds it" from `foreign` when
    /// the read-back says mode 1. A failed acquire is harmless here: the
    /// fan reads 0 or 3, no one is forcing it, and the next non-forced
    /// pass removes it.
    private var held: Set<Int> = []
    private var clouds: [Int: Histogram]
    private var sample = Sample()
    private var reason: Reason = .apple
    private var inFlight: Task<Void, Never>?
    private var thermalObserver: NSObjectProtocol?

    init(writer: SMCWriter, parts: Parts?, hid: Result<HIDSensors, Error>, intent: Intent) {
        self.writer = writer
        self.parts = parts
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

    /// Watch thermal pressure and run the loop. The lid is latched by the
    /// caller on the power queue once its notification is armed.
    func start() {
        Log.notice("thermal: \(thermal.spelled)")
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: nil
        ) { _ in
            Task { await self.thermalChanged() }
        }
        Task {
            while true {
                await evaluate()
                try? await clock.sleep(for: Engine.period)
            }
        }
    }

    /// Every fan back to Apple, on the way out of this process: nothing
    /// is forced from here on, the pass in flight drains, then the
    /// hand-back runs to completion before the caller exits.
    func shutdown(_ why: String) async {
        Log.notice("\(why): handing the fans back")
        halting = true
        await handBack()
    }

    // MARK: - verbs

    /// Intent = this curve. Presence is not claimed here: whoever watches
    /// (the app, a `--watch` CLI) carries it, so a CLI without `--watch`
    /// sets the intent and leaves while the app's presence keeps it.
    func use(_ data: Data, from peer: Peer) async -> Reply<State> {
        let curve: Curve
        do {
            curve = try Wire.decode(Curve.self, from: data)
        } catch {
            return .refused(.badCurve("\(error)"))
        }
        transition(to: .curve(curve), by: peer)
        await evaluate()
        return .ok(render())
    }

    func boost(minutes: Int, from peer: Peer) async -> Reply<State> {
        guard minutes > 0 else {
            return .refused(.unavailable("boost: minutes must be positive, got \(minutes)"))
        }
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

    /// A client's connection died: the presence IT claimed goes with it,
    /// and the fans go back on this evaluation, not the next tick. Keyed
    /// by the connection, so an older connection of the same process
    /// dying never drops the presence a newer one holds.
    func disconnected(session: Int) async {
        guard let current = watcher, current.session == session else { return }
        Log.notice("presence: \(current.name) (pid \(current.pid)) disconnected")
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

    /// The thermal state as ProcessInfo reads it NOW, not as the
    /// notification captured it: deliveries are unordered tasks, so a
    /// burst settles on the live value whichever lands last.
    func thermalChanged() {
        let now = ProcessInfo.processInfo.thermalState
        guard now != thermal else { return }
        Log.notice("thermal: \(thermal.spelled) -> \(now.spelled)")
        thermal = now
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
    /// holds it. Another PROCESS is another client; a new connection of
    /// the same process renews and takes the record over, so the death of
    /// its old connection cannot touch it. A watcher's message after a
    /// wake lifts the sleep veto.
    private func claim(_ peer: Peer) -> Refusal? {
        let now = clock.now
        if let other = watcher, other.pid != peer.pid, other.deadline > now {
            return .heldBy(pid: other.pid, name: other.name)
        }
        if watcher?.pid != peer.pid {
            Log.notice("presence: \(peer.name) (pid \(peer.pid)) watching")
        }
        watcher = Watcher(
            pid: peer.pid, session: peer.session, name: peer.name,
            deadline: now + Wire.presenceWindow)
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
    /// is the same write. Serialized behind the pass in flight, so no
    /// `govern` is mid-write when the writes land. A fan whose release
    /// failed stays `held`, so the next pass retries it instead of
    /// relabelling chill's own write as someone else's.
    private func handBack() async {
        await serialized { await self.reconcile() }
    }

    private func reconcile() async {
        do {
            try await writer.reconcile()
            held = []
        } catch WriterError.reconcile(let failures) {
            Log.error("hand back: \(WriterError.reconcile(failures))")
            held.formIntersection(failures.map(\.fan))
        } catch {
            Log.error("hand back: \(error)")
        }
    }

    // MARK: - the evaluator

    /// One pass: a caller that arrives while a pass or a hand-back is in
    /// flight waits for it and then runs its own, so a verb's reply always
    /// reflects a read-back taken after its intent change.
    func evaluate() async {
        await serialized { await self.step() }
    }

    private func serialized(_ job: @escaping @Sendable () async -> Void) async {
        while let running = inFlight {
            await running.value
            if inFlight == running { inFlight = nil }
        }
        let mine = Task { await job() }
        inFlight = mine
        await mine.value
        if inFlight == mine { inFlight = nil }
    }

    /// Whether `plan` is still what the world wants forced, read fresh
    /// after a suspension.
    private func stillForced(_ plan: Intent) -> Bool {
        !halting && intent == plan && plan != .system && watcher != nil && vetoes.isEmpty
    }

    private func step() async {
        let now = clock.now
        let (die, dieSensors, dieSource) = readDie()
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
        let plan = intent
        let forced = stillForced(plan)
        // One `Ftst` read per pass, re-read after any hand-back in it: a
        // fan judged after another's auto is judged on the post-write
        // value. A `Ftst` that cannot be read judges nothing: every fan
        // still waiting on it is unread, never "Apple's" by default.
        var ftst: UInt8?
        do {
            ftst = try await writer.ftst()
        } catch {
            Log.error("Ftst: \(error)")
            settle(
                Sample(
                    fans: [], die: die, dieSensors: dieSensors, dieSource: dieSource,
                    unread: writer.fans.map(\.index)),
                plan: plan, forced: forced)
            return
        }
        var fans: [FanState] = []
        var holders: [Holder] = []
        var unread: [Int] = []
        var refused: [(fan: Int, result: UInt8)] = []
        judge: for (i, fan) in writer.fans.enumerated() {
            do {
                let verdict = try await govern(
                    fan, plan: plan, forced: forced, die: die, ftst: ftst)
                fans.append(verdict.state)
                holders.append(verdict.holder)
                if let result = verdict.refused { refused.append((fan.index, result)) }
                if let die, verdict.holder == .apple {
                    clouds[fan.index]!.add(celsius: die, rpm: verdict.state.actual)
                }
                if verdict.released {
                    do {
                        ftst = try await writer.ftst()
                    } catch {
                        Log.error("Ftst: \(error)")
                        unread = writer.fans[(i + 1)...].map(\.index)
                        break judge
                    }
                }
            } catch is Moved {
                Log.notice("pass abandoned: the world moved under it")
                return
            } catch {
                Log.error("fan \(fan.index): \(error)")
                unread.append(fan.index)
            }
        }
        settle(
            Sample(
                fans: fans, die: die, dieSensors: dieSensors, dieSource: dieSource,
                holder: Engine.aggregate(holders), unread: unread, refused: refused),
            plan: plan, forced: forced)
    }

    /// The pass's read-back becomes the state every `render` ships, and
    /// the reason it implies is logged once per change.
    private func settle(_ next: Sample, plan: Intent, forced: Bool) {
        sample = next
        let why = currentReason(plan: plan, forced: forced)
        if why != reason {
            Log.notice("\(plan) · \(why)")
            reason = why
        }
    }

    /// One fan: read it back, then act on what it says. Under `forced`,
    /// the world is re-read after every suspension and a move abandons
    /// the pass before any write.
    private func govern(_ fan: Fan, plan: Intent, forced: Bool, die: Double?, ftst: UInt8?)
        async throws -> Governed
    {
        let n = fan.index
        let state = try await writer.read(fan: n)
        if forced {
            guard stillForced(plan) else { throw Moved() }
            guard state.mode == 1 else {
                if await !writer.isAcquiring(fan: n) {
                    guard stillForced(plan) else { throw Moved() }
                    Log.notice("fan \(n): mode \(state.mode), acquiring")
                    held.insert(n)
                    await writer.beginAcquire(fan: n)
                }
                return Governed(state: state, holder: .acquiring, released: false)
            }
            held.insert(n)
            var verdict = Governed(
                state: state, holder: .chill(curve: intentName(of: plan)), released: false)
            if let die {
                do {
                    try await writer.target(fan: n, rpm: wanted(fan, die: die, under: plan))
                } catch WriterError.targetRejected(_, let result, _, _) {
                    // The fan is chill's, read back in mode 1; only the
                    // number was refused. A failed READ is the other catch,
                    // in `step`, and lands the fan in `unread`.
                    verdict.refused = result
                }
            }
            return verdict
        }
        let forcedByAnyone = state.mode == 1 || ftst == 1
        let acquiring = await writer.isAcquiring(fan: n)
        if forcedByAnyone && (held.contains(n) || acquiring) {
            try await writer.auto(fan: n)
            held.remove(n)
            let after = try await writer.read(fan: n)
            return Governed(
                state: after, holder: after.mode == 1 ? .foreign : .apple, released: true)
        }
        held.remove(n)
        return Governed(state: state, holder: forcedByAnyone ? .foreign : .apple, released: false)
    }

    private func wanted(_ fan: Fan, die: Double, under plan: Intent) -> Double {
        switch plan {
        case .curve(let curve): return curve.target(at: die, for: fan)
        case .boost: return fan.max
        case .system: preconditionFailure("wanted() under intent system")
        }
    }

    private func intentName(of plan: Intent) -> String {
        switch plan {
        case .curve(let curve): return curve.name
        case .boost: return "boost"
        case .system: preconditionFailure("intentName under intent system")
        }
    }

    /// A fan someone else forced is `foreign` under ANY intent, before a
    /// veto or a missing watcher gets to say "Apple holds the fans".
    private func currentReason(plan: Intent, forced: Bool) -> Reason {
        if writer.fans.isEmpty { return .noFans }
        if let fan = sample.unread.first { return .unreadable(fan: fan) }
        if sample.holder == .foreign { return .foreign }
        if let refusal = sample.refused.first {
            return .targetRefused(fan: refusal.fan, result: refusal.result)
        }
        switch plan {
        case .system:
            return .apple
        case .curve, .boost:
            if let veto = Veto.order.first(where: vetoes.contains) { return .vetoed(veto) }
            if watcher == nil { return .noOneWatching }
            switch sample.holder {
            case .foreign, .apple, .acquiring: return .acquiring
            case .chill:
                if case .curve(let curve) = plan { return .curve(curve.name) }
                return .boost
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

    /// The temperature a curve follows, how many sensors it is the max
    /// of, and what it is: the hottest cpu or gpu sensor from the SMC's
    /// named keys where the catalogue knows this chip, else the hottest
    /// HID die (the SoC's blocks on M1/M2; the PMU's dies from M3 on).
    /// Never a mean.
    private func readDie() -> (celsius: Double?, sensors: Int, source: String) {
        if let top = parts?.hottest() {
            return (top.celsius, top.sensors, top.group.rawValue)
        }
        guard case .success(let sensors) = hid else { return (nil, 0, "die") }
        let dies = sensors.readings().filter { $0.block != .other }
        return (dies.map(\.celsius).max(), dies.count, "die")
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
            dieSensors: sample.dieSensors,
            dieSource: sample.dieSource,
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
