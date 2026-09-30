import AppKit
import ChillKit
import Keymap
import MachSensors
import Observation
import ServiceManagement
import SwiftUI

/// What the app knows about the daemon right now: its last `State`, why
/// none answers, that one answered and refused this process for good (a
/// chill older than chilld, or a reply this build cannot decode: quit and
/// relaunch from the bundle), or that this build cannot even ask (ad-hoc
/// signed, no peer requirement to derive).
enum Link: Equatable {
    case live(ChillKit.State)
    case down(ClientError)
    case stale(String)
    case bare(String)

    var state: ChillKit.State? {
        if case .live(let state) = self { return state }
        return nil
    }

    /// The one honest line, `chill status`'s words.
    var line: String {
        switch self {
        case .live(let state): return Status.line(state)
        case .down(let error): return error.description
        case .stale(let why): return why
        case .bare(let why): return "daemon: \(why); a bare build cannot reach chilld"
        }
    }

    static func == (a: Link, b: Link) -> Bool {
        switch (a, b) {
        case (.live(let x), .live(let y)): return Wire.encode(x) == Wire.encode(y)
        case (.down(let x), .down(let y)): return x.description == y.description
        case (.stale(let x), .stale(let y)): return x == y
        case (.bare(let x), .bare(let y)): return x == y
        default: return false
        }
    }
}

/// The app's one brain: the daemon link, the curves on disk, the curve
/// and the point under the pointer, the key registry with its router
/// and the system-wide toggle. Every surface (status item, menu, lab)
/// reads it and every action funnels through `perform`.
@MainActor @Observable
final class Model {

    let demo: Demo
    let store = KeymapStore<ChillAction>()
    @ObservationIgnored var router: LocalKeyRouter<ChillAction>?
    @ObservationIgnored var hotkeys: GlobalHotkeys<ChillAction>?
    @ObservationIgnored let float = FloatingPanel()
    @ObservationIgnored var canvas: CanvasWindow?
    /// The status item's popover, the surface the local keys land on.
    @ObservationIgnored weak var popover: NSPopover?
    /// Whether a plot is on screen. A hidden SwiftUI view keeps
    /// animating and a Canvas keeps redrawing at the display's rate,
    /// blur and all: with the popover closed that was half a core, all
    /// day. The plot exists only while its surface is up.
    var popoverShown = false
    var labShown = false
    /// The film's clock (`chill --demo film`), nil in a live session: set,
    /// every surface draws at this instant instead of the wall clock's, and
    /// what only a live session needs, the demo kicker and the shortcut
    /// hint, stays out of the picture.
    @ObservationIgnored var filmTime: Date?
    var filming: Bool { filmTime != nil }

    /// The instant a surface draws: the film's while filming, else `wall`.
    func now(_ wall: Date) -> Date { filmTime ?? wall }
    /// The shortcut panel and the about panel share the one floating
    /// panel; showing either dismisses the other.
    var showKeys = false { didSet { presentKeys(showKeys) } }
    var showAbout = false { didSet { presentAbout(showAbout) } }

    var link: Link?
    var hello: Hello?
    /// Another client holds presence; `takeOver` claims it.
    var heldBy: (pid: Int32, name: String)?
    /// A refusal or an error from the last verb, cleared by the next good
    /// exchange.
    var notice: String?
    /// The pulse's verdict: on the console, screens awake, unlocked, so this
    /// app claims presence. `aside` explains the fans being Apple's when
    /// it is false and no one else watches.
    var watching = false
    var curves: [Curve] = []
    /// The curve under the list cursor, by name.
    var cursor: String?
    /// The selected point of the cursor's curve.
    var point = 0
    var config: Config
    var local: LocalSample?

    let curveStore: CurveStore
    let clouds: CloudStore
    @ObservationIgnored private var client: Client?
    @ObservationIgnored private var busy = false
    /// The verbs in flight, each behind the one before: `link` is set by
    /// replies in the order the verbs were sent, never by whichever lands
    /// last.
    @ObservationIgnored private var verbs: Task<Void, Never>?
    @ObservationIgnored private var sensors: Result<LocalSensors, Error>?
    @ObservationIgnored private var cloudTimer: Timer?
    @ObservationIgnored private var retuneLanding: Task<Void, Never>?

    init(demo: Demo) throws {
        self.demo = demo
        curveStore = try CurveStore(demo: demo)
        clouds = try CloudStore(demo: demo)
        config = try Config.load(demo)
        curves = try curveStore.list()
        cursor = config.lastCurve.flatMap { name in curves.first { $0.name == name }?.name }
        // Opened at launch, once: the badge reads parts on demand, the
        // daemon-less plot samples it, and the probe logs which catalogue
        // keys this Mac answers while there is still time to read it.
        sensors = Result { try LocalSensors() }
        // Common modes: a timer on the default mode alone stalls while a
        // menu is open or a window resizes.
        let timer = Timer(timeInterval: CloudStore.writePeriod, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.writeClouds() }
        }
        RunLoop.main.add(timer, forMode: .common)
        cloudTimer = timer
    }

    // MARK: - reads

    var state: ChillKit.State? { link?.state }

    var editing: Curve? { curves.first { $0.name == cursor } }

    /// The curve the daemon's intent names, if any.
    var intentCurve: String? {
        if case .curve(let curve)? = state?.intent { return curve.name }
        return nil
    }

    /// The fans' reported envelope, lowest Mn to highest Mx: from `hello`
    /// with a daemon, the SMC's own numbers without one (read once when
    /// the local sensors open, never live), nil with neither (the status
    /// line says why there is no daemon; nothing is invented).
    var envelope: ClosedRange<Double>? {
        if let fans = hello?.fans, !fans.isEmpty {
            return fans.map(\.min).min()!...fans.map(\.max).max()!
        }
        if case .success(let sensors)? = sensors { return sensors.envelope }
        return nil
    }

    var die: Double? { state?.die ?? local?.die }

    /// What the status line cannot say: another watcher holds the fans
    /// (the take-over button sits beside it), else the last verb's
    /// refusal or error (both clear on the next good exchange), else why
    /// this app, open as it is, claims no presence.
    var aside: String? {
        if let held = heldBy {
            return "held by \(held.name) (pid \(held.pid))"
        }
        if let notice { return notice }
        if !watching, let state, state.presence == nil {
            return "not watching: off the console, screens asleep or locked"
        }
        return nil
    }

    var actuals: [Double] { state?.fans.map(\.actual) ?? local?.fans.map(\.actual) ?? [] }

    /// Where the live point has been, fed by the plot's animated layer
    /// frame by frame; a reference, since the layer writes into it while
    /// drawing.
    @ObservationIgnored let trail = Trail()

    /// The die sensors by heat, read from the machine on demand for the
    /// temperature hover card (the daemon ships one number, the hottest;
    /// the names live only in the HID reader). Opens the local sensors
    /// once, the same object the daemon-less canvas samples.
    func temperatures() -> [Sensor] {
        if sensors == nil { sensors = Result { try LocalSensors() } }
        guard case .success(let local)? = sensors else { return [] }
        return local.temperatures()
    }

    /// cpu, gpu, memory by their SMC keys, read on demand for the badge.
    func parts() -> [Parts.Reading] {
        if sensors == nil { sensors = Result { try LocalSensors() } }
        guard case .success(let local)? = sensors else { return [] }
        return local.partReadings()
    }

    /// The parts in one line for the foot: `cpu 55 · gpu 47 · ssd 36 ·
    /// battery 33 °C`, hottest of each.
    var partsLine: String {
        // The demo's machine is scripted: its one number is the die the
        // demo daemon ships, never this Mac's sensors.
        if demo.on {
            return state?.die.map { "\(state!.dieSource) \(Int($0.rounded())) °C" } ?? ""
        }
        var items = parts().map { "\($0.group.rawValue) \(Int($0.celsius.max()!.rounded()))" }
        items += Badge.named(temperatures()).map { "\($0.name) \(Int($0.celsius.rounded()))" }
        return items.isEmpty ? "" : items.joined(separator: " · ") + " °C"
    }

    /// The exact numbers behind the plot's marks, one line per fan, for
    /// the hover card: actual, target, and who holds it by its mode.
    var fanLines: [String] {
        func mode(_ m: UInt8) -> String {
            switch m {
            case 0: return "auto"
            case 1: return "forced"
            case 3: return "apple"
            default: return "mode \(m)"
            }
        }
        if let state {
            return state.fans.map {
                "fan \($0.index + 1) · \(Int($0.actual)) rpm · target \(Int($0.target)) · \(mode($0.mode))"
            }
        }
        return local?.fans.map {
            "fan \($0.index + 1) · \(Int($0.actual)) rpm · target \(Int($0.target)) · \(mode($0.mode))"
        } ?? []
    }

    /// The daemon's targets, only meaningful while it holds the fans.
    var targets: [Double] {
        guard let state, case .chill = state.holder else { return [] }
        return state.fans.map(\.target)
    }

    var statusLine: String { demo.mark(link?.line ?? "daemon: connecting") }

    // MARK: - the pulse

    /// One exchange per second: presence while watching, a read otherwise.
    /// A transport failure drops the client so the next pulse rebuilds it
    /// (and re-reads the registration through `ClientError`); a refused
    /// presence means another watcher holds the fans; any other answer
    /// from a daemon that spoke (a stale-client refusal, a reply this
    /// build cannot decode) is `stale`, the client kept: nothing to
    /// rebuild, the fix is a relaunch.
    func pulse(watching: Bool) async {
        if watching != self.watching {
            log.info("presence: \(watching ? "watching" : "not watching", privacy: .public)")
        }
        self.watching = watching
        guard !busy else {
            log.debug("pulse skipped: the last one has not answered")
            return
        }
        busy = true
        defer { busy = false }
        guard let client = connect() else {
            sampleLocally()
            return
        }
        do {
            let state = watching ? try await client.presence() : try await client.state()
            heldBy = nil
            await arrived(state, from: client)
        } catch let error as ClientError {
            switch error {
            case .refused(.heldBy(let pid, let name)):
                heldBy = (pid, name)
                do {
                    await arrived(try await client.state(), from: client)
                } catch {
                    drop(error)
                }
            case .refused, .malformed:
                link = .stale(error.description)
            case .notInstalled, .awaitingApproval, .unreachable:
                drop(error)
            }
        } catch {
            drop(error)
        }
    }

    private func arrived(_ state: ChillKit.State, from client: Client) async {
        if hello == nil {
            hello = try? await client.hello()
            if hello != nil { ensureTuned() }
        }
        if link?.state == nil {
            log.info("link live: \(state.lastReason, privacy: .public)")
        }
        link = Link.live(state)
        local = nil
        if let hello { clouds.absorb(state.clouds, from: hello.pid) }
    }

    // MARK: - the built-in curve

    /// The curve most people run: the fan's minimum until `kickIn`, then
    /// one clean S to its maximum over 45 °C (gentle) down to 15 °C
    /// (steep). Two points only: between them the interpolation's flat
    /// end tangents make an exact smoothstep, and a third point would
    /// put a hump on either side of itself. Named `chill`, on disk like
    /// any curve, so `chill curve use chill` and the canvas see the same
    /// one.
    static let tunedName = "chill"

    /// One knob, `push` 0 to 1, in acts that blend into each other
    /// (keyframes, smoothstep between). First only the S comes closer:
    /// the kick-in and the top move left, the floor stays the fan's
    /// minimum (the firmware's; an Apple Silicon fan never stops), so at
    /// rest chill does not intervene. Then the S nearly halts and the
    /// floor rises, to about 4000 rpm by the middle: the laptop-on-lap
    /// point, cool without much noise. Then the floor creeps while the S
    /// steepens and comes in. Last, everything flattens to the ceiling,
    /// every fan flat out, which is why no separate boost tab exists.
    /// `floor` is a fraction of the envelope.
    static let acts: [(push: Double, kickIn: Double, span: Double, floor: Double)] = [
        (0.00, 65, 45, 0.00),
        (0.25, 52, 32, 0.05),
        (0.50, 49, 28, 0.32),
        (0.80, 43, 16, 0.42),
        (1.00, 40, 15, 1.00),
    ]

    static func tuned(push: Double, envelope: ClosedRange<Double>) -> Curve {
        let p = min(1, max(0, push))
        let i = max(0, min(acts.count - 2, acts.lastIndex { $0.push <= p } ?? 0))
        let (a, b) = (acts[i], acts[i + 1])
        let t = (p - a.push) / (b.push - a.push)
        let s = t * t * (3 - 2 * t)
        func mix(_ x: Double, _ y: Double) -> Double { x + (y - x) * s }
        let floor =
            envelope.lowerBound
            + (envelope.upperBound - envelope.lowerBound) * mix(a.floor, b.floor)
        let kickIn = mix(a.kickIn, b.kickIn)
        let span = mix(a.span, b.span)
        return try! Curve(
            name: tunedName,
            points: [
                Curve.Point(c: kickIn, rpm: floor),
                Curve.Point(c: kickIn + span, rpm: envelope.upperBound),
            ])
    }

    var tuned: Curve? {
        envelope.map { Model.tuned(push: config.push, envelope: $0) }
    }

    /// The built-in curve exists on disk from the first envelope on.
    /// The file on disk is the computed curve, always: written when it is
    /// missing and rewritten when the knobs' shape has changed under it.
    private func ensureTuned() {
        guard let tuned, curves.first(where: { $0.name == Model.tunedName }) != tuned else {
            return
        }
        do {
            try curveStore.save(tuned)
            reload()
        } catch {
            notice = "\(error)"
        }
    }

    /// The knob moved: the file follows, and the daemon when it runs it.
    /// The knob moves at pointer rate; the plot follows every step (the
    /// curve is computed from `config`), but the disk and the daemon get
    /// one landing, the last value, `retuneSettle` after the pointer
    /// stops: a drag is not sixty intents.
    func retune(push: Double) {
        config.push = push
        retuneLanding?.cancel()
        retuneLanding = Task { [weak self] in
            try? await Task.sleep(for: Model.retuneSettle)
            guard !Task.isCancelled, let self else { return }
            self.landRetune()
        }
    }

    static let retuneSettle: Duration = .milliseconds(150)

    private func landRetune() {
        saveConfig()
        guard let tuned else { return }
        do {
            try curveStore.save(tuned)
            reload()
            if intentCurve == Model.tunedName {
                call("use chill (retune)") { try await $0.use(tuned) }
            }
        } catch {
            notice = "\(error)"
        }
    }

    /// The popover's tabs ARE the intents: Apple's curve, the built-in
    /// one, each custom curve. The selected tab is read from the daemon,
    /// never remembered; picking one sends it.
    enum Tab: Hashable {
        case apple, tuned
        /// Only the CLI's `boost` puts the daemon here; the rail has no
        /// tab for it, chill at full push is the same curve.
        case gust
        case custom(String)
    }

    var tab: Tab {
        switch state?.intent {
        case .curve(let curve)?:
            return curve.name == Model.tunedName ? .tuned : .custom(curve.name)
        case .boost?:
            return .gust
        default:
            return .apple
        }
    }

    var customCurves: [Curve] { curves.filter { $0.name != Model.tunedName } }

    func select(_ tab: Tab) {
        log.info(
            "tab \(String(describing: tab), privacy: .public) pressed; daemon runs \(String(describing: self.tab), privacy: .public), link \(self.state == nil ? "not live" : "live", privacy: .public)"
        )
        switch tab {
        case .apple:
            system()
        case .tuned:
            guard let tuned else {
                notice = "no fan envelope yet: no daemon and no SMC"
                return
            }
            use(tuned)
        case .custom(let name):
            guard let curve = curves.first(where: { $0.name == name }) else { return }
            cursor = name
            point = 0
            use(curve)
        case .gust:
            // No tab sends it; the CLI's boost verb does.
            break
        }
    }

    /// How many curves of your own the tab rail holds: two, so every tab
    /// keeps its name whole at the popover's width.
    static let maxCustom = 2

    /// `+`: a custom curve born as a copy of the built-in one, run at
    /// once, drawn in place with the pointer.
    func newCurveTab() {
        log.info("+ pressed")
        guard customCurves.count < Model.maxCustom else {
            notice = "two curves of your own is the rail; trash one to draw another"
            return
        }
        guard let tuned else {
            notice = "no fan envelope yet: no daemon and no SMC"
            return
        }
        let name = freshName()
        commit(name, tuned.points, select: tuned.points[0])
        cursor = name
        point = 0
        if let curve = curves.first(where: { $0.name == name }) { use(curve) }
    }

    private func drop(_ error: Error) {
        log.error(
            "link down: \(error, privacy: .public); tabs disabled until the next pulse answers")
        link = .down(error as? ClientError ?? .unreachable("\(error)"))
        client = nil
        hello = nil
        sampleLocally()
    }

    private func connect() -> Client? {
        if let client { return client }
        do {
            client = try Client(demo: demo, role: .app)
            return client
        } catch {
            link = .bare("\(error)")
            return nil
        }
    }

    /// Without a daemon the canvas still shows the machine: the package's
    /// read-only sensors, opened once, given up once.
    private func sampleLocally() {
        if sensors == nil { sensors = Result { try LocalSensors() } }
        switch sensors! {
        case .success(let sensors):
            local = sensors.sample()
        case .failure(let error):
            if local == nil { Verbs.note("chill: \(error); no local telemetry") }
            local = LocalSample(die: nil, fans: [])
        }
    }

    // MARK: - verbs

    func use(_ curve: Curve) {
        config.lastCurve = curve.name
        saveConfig()
        call("use \(curve.name)") { try await $0.use(curve) }
    }

    func system() { call("system") { try await $0.system() } }

    func takeOver() { call("take") { try await $0.take() } }

    /// The daemon in one line for the app menu.
    var daemonLine: String {
        switch link {
        case .live?: return "chilld \(hello?.daemonVersion ?? "") · pid \(hello?.pid ?? 0)"
        case .down(let error)?: return "chilld: \(error.description)"
        case .stale(let why)?: return "chilld: \(why)"
        case .bare(let why)?: return "chilld: \(why)"
        case nil: return "chilld: connecting"
        }
    }

    /// Start at login: the login item `chill daemon install` registers,
    /// switched here; the daemon is untouched either way.
    func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
                log.info("login item: off")
            } else {
                try SMAppService.mainApp.register()
                log.info("login item: on")
            }
        } catch {
            notice = "start at login: \(error.localizedDescription)"
        }
    }

    /// The prior art, as README says it, for the about panel.
    static let credits = """
        Fan control for the Mac, with Apple in charge by default.

        Prior art: SoloFan's Swift app (MIT, github.com/SoloTeamDev/solofan). \
        The Ftst unlock: agoodkind/macos-smc-fan (MIT). \
        The SMC keys that name the chip's parts: exelban/stats (MIT). \
        Sensors through swift-hw, read-only by construction.

        MIT. github.com/adriangalilea/chill
        """

    /// One verb, behind the verbs before it: a held arrow key sends a `use`
    /// per repeat, and the daemon runs them in wire order, so the replies
    /// land in that order too and `link` never wears a stale one.
    private func call(
        _ name: String, _ job: @escaping (Client) async throws -> ChillKit.State
    ) {
        guard let client = connect() else {
            log.error(
                "verb \(name, privacy: .public): no client, link \(self.link.map { "\($0)" } ?? "nil", privacy: .public)"
            )
            return
        }
        let before = verbs
        let queued = ContinuousClock.now
        log.info(
            "verb \(name, privacy: .public): queued\(before == nil ? "" : " behind another", privacy: .public)"
        )
        verbs = Task {
            await before?.value
            let started = ContinuousClock.now
            do {
                let state = try await job(client)
                log.info(
                    "verb \(name, privacy: .public): ok in \(Model.ms(started), privacy: .public) ms (waited \(Model.ms(queued, until: started), privacy: .public) ms) → \(state.intent, privacy: .public) · \(state.lastReason, privacy: .public)"
                )
                notice = nil
                heldBy = nil
                await arrived(state, from: client)
            } catch let error as ClientError {
                log.error(
                    "verb \(name, privacy: .public): \(error, privacy: .public) after \(Model.ms(started), privacy: .public) ms"
                )
                switch error {
                case .refused(.heldBy(let pid, let name)):
                    heldBy = (pid, name)
                    notice = error.description
                case .refused(.stale), .malformed:
                    link = .stale(error.description)
                case .refused(let refusal):
                    notice = refusal.description
                case .notInstalled, .awaitingApproval, .unreachable:
                    drop(error)
                }
            } catch {
                log.error(
                    "verb \(name, privacy: .public): \(error, privacy: .public) after \(Model.ms(started), privacy: .public) ms"
                )
                drop(error)
            }
        }
    }

    private static func ms(_ since: ContinuousClock.Instant, until: ContinuousClock.Instant = .now)
        -> Int
    {
        Int((until - since) / .milliseconds(1))
    }

    // MARK: - the no-daemon menu

    /// The daemon's registration as SMAppService reports it this instant.
    var registration: SMAppService.Status { Client.registration }

    /// The same two registrations `chill daemon install` makes, so a cask
    /// install (whose steps cannot reach SMAppService) resumes at login too.
    func installDaemon() {
        do {
            try SMAppService.daemon(plistName: Wire.plistName).register()
            try SMAppService.mainApp.register()
            notice = nil
        } catch {
            notice = "install chilld: \(error.localizedDescription)"
        }
    }

    func approveDaemon() { SMAppService.openSystemSettingsLoginItems() }

    // MARK: - curves and points

    func reload() {
        do {
            curves = try curveStore.list()
        } catch {
            notice = "\(error)"
        }
        if cursor.map({ name in !curves.contains { $0.name == name } }) ?? true {
            cursor = curves.first?.name
        }
        if let editing { point = min(point, editing.points.count - 1) }
    }

    /// The pointer's way to draw: a click on the plot lands a point there.
    /// No curve under the cursor means the click founds one; a point
    /// within a degree of the click is moved to it instead of doubled.
    func place(celsius: Double, rpm: Double) {
        guard let editing else {
            let placed = Curve.Point(c: celsius.rounded(), rpm: max(0, rpm.rounded()))
            let name = freshName()
            commit(name, [placed], select: placed)
            cursor = name
            point = 0
            return
        }
        let others = editing.points.filter { abs($0.c - celsius.rounded()) >= 1 }
        let placed = Model.held(
            Curve.Point(c: celsius.rounded(), rpm: rpm.rounded()), among: others)
        commit(editing.name, others + [placed], select: placed)
    }

    /// A drag: the point under the pointer follows it, held between its
    /// neighbours' rpm.
    func drag(_ index: Int, celsius: Double, rpm: Double) {
        guard let editing, editing.points.indices.contains(index) else { return }
        var others = editing.points
        others.remove(at: index)
        others.removeAll { abs($0.c - celsius.rounded()) < 1 }
        let moved = Model.held(Curve.Point(c: celsius.rounded(), rpm: rpm.rounded()), among: others)
        commit(editing.name, others + [moved], select: moved)
    }

    /// A fan curve never comes back down: a point sits no lower than the
    /// one before it and no higher than the one after. The pointer can
    /// ask; the point stops at the neighbour's rpm, and `held` says so.
    static func held(_ p: Curve.Point, among others: [Curve.Point]) -> Curve.Point {
        let floor = others.filter { $0.c < p.c }.map(\.rpm).max() ?? 0
        let ceiling = others.filter { $0.c > p.c }.map(\.rpm).min() ?? .infinity
        return Curve.Point(c: p.c, rpm: min(ceiling, max(floor, p.rpm)))
    }

    /// The point's numbers, and why they stopped where they did.
    func heldNote(_ p: Curve.Point) -> String? {
        guard let editing else { return nil }
        let others = editing.points.filter { abs($0.c - p.c) >= 1 }
        if let before = others.filter({ $0.c < p.c }).max(by: { $0.rpm < $1.rpm }),
            p.rpm == before.rpm
        {
            return "no lower than the point before"
        }
        if let after = others.filter({ $0.c > p.c }).min(by: { $0.rpm < $1.rpm }),
            p.rpm == after.rpm
        {
            return "no higher than the point after"
        }
        return nil
    }

    func removePoint() {
        guard let editing, editing.points.count > 1, editing.points.indices.contains(point) else {
            return
        }
        var points = editing.points
        points.remove(at: point)
        commit(editing.name, points, select: points[min(point, points.count - 1)])
    }

    /// Every edit lands: validated, written, and pushed to the daemon when
    /// this is the curve it runs. The selection follows the point moved
    /// (sorting may reorder it).
    private func commit(_ name: String, _ points: [Curve.Point], select: Curve.Point) {
        do {
            let curve = try Curve(name: name, points: points)
            try curveStore.save(curve)
            reload()
            point = curve.points.firstIndex { $0.c == select.c } ?? 0
            notice = nil
            if intentCurve == curve.name {
                call("use \(curve.name) (edit)") { try await $0.use(curve) }
            }
        } catch {
            notice = "\(error)"
        }
    }

    /// `custom`, then `custom-2`, `custom-3`: the first name not on disk.
    private func freshName() -> String {
        var name = "custom"
        var n = 1
        while curves.contains(where: { $0.name == name }) {
            n += 1
            name = "custom-\(n)"
        }
        return name
    }

    /// To the Trash, never gone; the daemon is handed back first when it
    /// runs this curve.
    func deleteCurve() {
        guard let editing else { return }
        // The house curve is not a file the user owns; it is regenerated
        // from the knob, and trashing it would only bring it back.
        guard editing.name != Model.tunedName else {
            notice = "chill is the house curve; it stays"
            return
        }
        if intentCurve == editing.name { system() }
        do {
            try FileManager.default.trashItem(
                at: curveStore.url(editing.name), resultingItemURL: nil)
            if config.lastCurve == editing.name {
                config.lastCurve = nil
                saveConfig()
            }
            reload()
        } catch {
            notice = "\(error)"
        }
    }

    private func saveConfig() {
        do {
            try config.save(demo)
        } catch {
            notice = "config: \(error)"
        }
    }

    // MARK: - keys

    func startKeys() {
        guard router == nil else { return }
        router = LocalKeyRouter(
            store: store,
            shouldRoute: { [weak self] action, event in
                guard let self, let window = event.window else {
                    log.debug("key \(event.keyCode): no window, not routed")
                    return false
                }
                let ours =
                    window === self.canvas?.window
                    || window === self.popover?.contentViewController?.view.window
                if !ours {
                    log.debug(
                        "key \(event.keyCode) (\(action.map { $0.rawValue } ?? "none", privacy: .public)): in a window that is not ours, not routed"
                    )
                }
                return ours
            },
            perform: { [weak self] in self?.perform($0) })
        // The system-wide plane: the toggle, from any app. Carbon, so no
        // accessibility permission; a combo another app owns is inert,
        // said in the log and dimmed in the shortcut panel.
        hotkeys = GlobalHotkeys(store: store) { [weak self] in self?.perform($0) }
        for dead in store.deadGlobals {
            log.error("global \(dead.display, privacy: .public) is owned by another app; inert")
        }
        store.publish(appName: "chill", accent: Palette.duneHex)
    }

    func perform(_ action: ChillAction) {
        log.info("action \(action.rawValue, privacy: .public)")
        switch action {
        case .toggle: toggle()
        case .useCurve: if let editing { use(editing) }
        case .newCurve: newCurveTab()
        case .deleteCurve: deleteCurve()
        case .system: system()
        case .takeOver: takeOver()
        case .canvas: openCanvas()
        case .back:
            if showKeys {
                showKeys = false
            } else if showAbout {
                showAbout = false
            } else if let popover, popover.isShown {
                popover.performClose(nil)
            } else {
                canvas?.close()
            }
        case .quit: NSApp.terminate(nil)
        }
    }

    /// The curve the toggle brings back: the last one used, chill until
    /// you draw one.
    var yourCurve: Curve? { curves.first(where: { $0.name == config.lastCurve }) ?? tuned }

    /// "got it" under the shortcut tip: the dot and the tip are gone for
    /// good; the app menu still says the combo.
    func dismissKeyHint() {
        config.keyHintDismissed = true
        saveConfig()
    }

    /// The tab the toggle would press right now: yours while Apple's
    /// runs, Apple's otherwise. That tab wears the shortcut.
    var toggleTarget: Tab {
        guard tab == .apple else { return .apple }
        guard let yourCurve else { return .tuned }
        return yourCurve.name == Model.tunedName ? .tuned : .custom(yourCurve.name)
    }

    /// The one key from anywhere: a curve runs, so Apple's; Apple's runs,
    /// so yours, the last one used, chill until you draw one.
    func toggle() {
        guard tab == .apple else {
            system()
            return
        }
        guard let yourCurve else {
            notice = "no fan envelope yet: no daemon and no SMC"
            return
        }
        use(yourCurve)
    }

    func openCanvas() {
        if canvas == nil { canvas = CanvasWindow(model: self) }
        canvas!.open()
    }

    private func presentKeys(_ on: Bool) {
        guard on else {
            float.dismiss()
            store.keyboardCaptured = false
            log.info("keys: dismissed")
            return
        }
        log.info("keys: showing")
        if showAbout { showAbout = false }
        float.onDismissRequest = { [weak self] in self?.showKeys = false }
        // Not on app switch: opening from the status item ACTIVATES this
        // app, and that activation lands after the panel is up, which
        // dismissed it before it was seen. The panel's own click and
        // escape monitors still close it.
        float.show(
            KeysPanel(store: store, close: { [weak self] in self?.showKeys = false })
                .glassEffect(.regular, in: .rect(cornerRadius: .inkPanel)),
            size: KeysPanel.size, on: NSApp.keyWindow?.screen,
            dismissOnAppSwitch: false)
    }

    private func presentAbout(_ on: Bool) {
        guard on else {
            float.dismiss()
            log.info("about: dismissed")
            return
        }
        log.info("about: showing")
        if showKeys { showKeys = false }
        float.onDismissRequest = { [weak self] in self?.showAbout = false }
        float.show(
            AboutPanel(close: { [weak self] in self?.showAbout = false })
                .glassEffect(.regular, in: .rect(cornerRadius: .inkPanel)),
            size: AboutPanel.size, on: NSApp.keyWindow?.screen,
            dismissOnAppSwitch: false)
    }

    // MARK: - persistence

    func writeClouds() {
        do {
            try clouds.write()
        } catch {
            Verbs.note("chill: cloud write: \(error)")
        }
    }

    /// Quit is a transition: the clouds land, the connection dies with the
    /// process and the daemon drops this presence on invalidation.
    func quit() {
        writeClouds()
    }
}
