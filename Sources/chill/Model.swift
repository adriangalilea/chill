import AppKit
import ChillKit
import Keymap
import Observation
import ServiceManagement
import SwiftUI

/// What the app knows about the daemon right now: its last `State`, why
/// none answers, or that this build cannot even ask (ad-hoc signed, no
/// peer requirement to derive).
enum Link: Equatable {
    case live(ChillKit.State)
    case down(ClientError)
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
        case .bare(let why): return "daemon: \(why); a bare build cannot reach chilld"
        }
    }

    static func == (a: Link, b: Link) -> Bool {
        switch (a, b) {
        case (.live(let x), .live(let y)): return Wire.encode(x) == Wire.encode(y)
        case (.down(let x), .down(let y)): return x.description == y.description
        case (.bare(let x), .bare(let y)): return x == y
        default: return false
        }
    }
}

/// The app's one brain: the daemon link, the curves on disk, the canvas
/// cursor and the point under edit, the key registry and its router. Every
/// surface (status item, menu, canvas, cheat sheet) reads it and every
/// action funnels through `perform`.
@MainActor @Observable
final class Model {
    nonisolated static let rpmStep = Double(Cloud.rpmBin)
    nonisolated static let celsiusStep = 1.0
    nonisolated static let boostMinutes = 5

    let demo: Demo
    let store = KeymapStore<ChillAction>(families: [ChillAction.curveFamily])
    @ObservationIgnored var router: LocalKeyRouter<ChillAction>?
    @ObservationIgnored let float = FloatingPanel()
    @ObservationIgnored var canvas: CanvasWindow?
    var showHelp = false { didSet { presentHelp(showHelp) } }

    var link: Link?
    var hello: Hello?
    /// Another client holds presence; `takeOver` claims it.
    var heldBy: (pid: Int32, name: String)?
    /// A refusal or an error from the last verb, cleared by the next good
    /// exchange.
    var notice: String?
    /// The pulse's verdict: on the console with the screens awake.
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
    @ObservationIgnored private var sensors: Result<LocalSensors, Error>?
    @ObservationIgnored private var cloudTimer: Timer?

    init(demo: Demo) throws {
        self.demo = demo
        curveStore = try CurveStore(demo: demo)
        clouds = try CloudStore(demo: demo)
        config = try Config.load(demo)
        curves = try curveStore.list()
        cursor = config.lastCurve.flatMap { name in curves.first { $0.name == name }?.name }
        cloudTimer = Timer.scheduledTimer(
            withTimeInterval: CloudStore.writePeriod, repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.writeClouds() }
        }
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
    /// with a daemon, the SMC without one, a plausible span with neither.
    var envelope: ClosedRange<Double> {
        if let fans = hello?.fans, !fans.isEmpty {
            return fans.map(\.min).min()!...fans.map(\.max).max()!
        }
        if let fans = local?.fans, !fans.isEmpty {
            return fans.map(\.min).min()!...fans.map(\.max).max()!
        }
        return 1000...8000
    }

    var die: Double? { state?.die ?? local?.die }

    var actuals: [Double] { state?.fans.map(\.actual) ?? local?.fans.map(\.actual) ?? [] }

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
    /// presence means another watcher holds the fans.
    func pulse(watching: Bool) async {
        self.watching = watching
        guard !busy else { return }
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
        } catch ClientError.refused(.heldBy(let pid, let name)) {
            heldBy = (pid, name)
            do {
                await arrived(try await client.state(), from: client)
            } catch {
                drop(error)
            }
        } catch {
            drop(error)
        }
    }

    private func arrived(_ state: ChillKit.State, from client: Client) async {
        if hello == nil { hello = try? await client.hello() }
        link = Link.live(state)
        local = nil
        if let hello { clouds.absorb(state.clouds, from: hello.pid) }
    }

    private func drop(_ error: Error) {
        link = .down(error as? ClientError ?? .unreachable("\(error)"))
        client = nil
        hello = nil
        sampleLocally()
    }

    private func connect() -> Client? {
        if let client { return client }
        do {
            client = try Client(demo: demo)
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
        case .success(let sensors): local = sensors.sample()
        case .failure(let error):
            if local == nil { Verbs.note("chill: \(error); no local telemetry") }
            local = LocalSample(die: nil, fans: [])
        }
    }

    // MARK: - verbs

    func use(_ curve: Curve) {
        config.lastCurve = curve.name
        saveConfig()
        call { try await $0.use(curve) }
    }

    func boost() { call { try await $0.boost(minutes: Model.boostMinutes) } }

    func system() { call { try await $0.system() } }

    func takeOver() { call { try await $0.take() } }

    /// Right-click: system ↔ the last curve.
    func toggle() {
        guard let state else { return }
        if state.intent != .system {
            system()
        } else if let last = config.lastCurve, let curve = curves.first(where: { $0.name == last })
        {
            use(curve)
        } else {
            notice = "no last curve: pick one first"
        }
    }

    private func call(_ job: @escaping (Client) async throws -> ChillKit.State) {
        guard let client = connect() else { return }
        Task {
            do {
                let state = try await job(client)
                notice = nil
                heldBy = nil
                await arrived(state, from: client)
            } catch ClientError.refused(let refusal) {
                if case .heldBy(let pid, let name) = refusal { heldBy = (pid, name) }
                notice = refusal.description
            } catch {
                drop(error)
            }
        }
    }

    // MARK: - the no-daemon menu

    /// The daemon's registration as SMAppService reports it this instant.
    var registration: SMAppService.Status { Client.registration }

    func installDaemon() {
        do {
            try SMAppService.daemon(plistName: Wire.plistName).register()
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

    func moveCursor(_ delta: Int) {
        guard !curves.isEmpty else { return }
        let index = curves.firstIndex { $0.name == cursor } ?? 0
        cursor = curves[max(0, min(curves.count - 1, index + delta))].name
        point = 0
    }

    func pick(_ number: Int) {
        guard curves.indices.contains(number - 1) else { return }
        cursor = curves[number - 1].name
        point = 0
        use(curves[number - 1])
    }

    func movePoint(_ delta: Int) {
        guard let editing else { return }
        point = (point + delta + editing.points.count) % editing.points.count
    }

    func nudge(celsius: Double, rpm: Double) {
        guard let editing, editing.points.indices.contains(point) else { return }
        var points = editing.points
        let old = points[point]
        let moved = Curve.Point(c: old.c + celsius, rpm: max(0, old.rpm + rpm))
        points[point] = moved
        commit(editing.name, points, select: moved)
    }

    func addPoint() {
        guard let editing, editing.points.indices.contains(point) else { return }
        var points = editing.points
        let here = points[point]
        let next = point + 1 < points.count ? points[point + 1] : nil
        let added = Curve.Point(
            c: next.map { (here.c + $0.c) / 2 } ?? here.c + 5,
            rpm: next.map { (here.rpm + $0.rpm) / 2 } ?? here.rpm)
        points.insert(added, at: point + 1)
        commit(editing.name, points, select: added)
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
            if intentCurve == curve.name { call { try await $0.use(curve) } }
        } catch {
            notice = "\(error)"
        }
    }

    func newCurve() {
        var name = "curve"
        var n = 1
        while curves.contains(where: { $0.name == name }) {
            n += 1
            name = "curve-\(n)"
        }
        let span = envelope
        let fresh = Curve.Point(c: 50, rpm: span.lowerBound)
        commit(name, [fresh, Curve.Point(c: 90, rpm: span.upperBound)], select: fresh)
        cursor = name
        point = 0
    }

    /// To the Trash, never gone; the daemon is handed back first when it
    /// runs this curve.
    func deleteCurve() {
        guard let editing else { return }
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
            shouldRoute: { [weak self] _, event in
                guard let self, let window = event.window else { return false }
                return window === self.canvas?.window
            },
            perform: { [weak self] in self?.perform($0) },
            performFamily: { [weak self] _, key in self?.pick(Int(key)!) })
        store.publish(appName: "chill", accent: "#dff3ff")
    }

    func perform(_ action: ChillAction) {
        switch action {
        case .pointUp: nudge(celsius: 0, rpm: Model.rpmStep)
        case .pointDown: nudge(celsius: 0, rpm: -Model.rpmStep)
        case .pointLeft: nudge(celsius: -Model.celsiusStep, rpm: 0)
        case .pointRight: nudge(celsius: Model.celsiusStep, rpm: 0)
        case .nextPoint: movePoint(1)
        case .previousPoint: movePoint(-1)
        case .addPoint: addPoint()
        case .removePoint: removePoint()
        case .previousCurve: moveCursor(-1)
        case .nextCurve: moveCursor(1)
        case .useCurve: if let editing { use(editing) }
        case .newCurve: newCurve()
        case .deleteCurve: deleteCurve()
        case .boost: boost()
        case .system: system()
        case .takeOver: takeOver()
        case .canvas: openCanvas()
        case .back:
            if showHelp {
                showHelp = false
            } else {
                canvas?.close()
            }
        case .help: showHelp.toggle()
        case .quit: NSApp.terminate(nil)
        }
    }

    func openCanvas() {
        if canvas == nil { canvas = CanvasWindow(model: self) }
        canvas!.open()
    }

    private func presentHelp(_ on: Bool) {
        guard on else {
            float.dismiss()
            store.keyboardCaptured = false
            return
        }
        float.onDismissRequest = { [weak self] in self?.showHelp = false }
        float.show(
            CheatSheetPanel(
                store: store, perform: { [weak self] in self?.perform($0) },
                extras: [
                    (
                        name: "pointer",
                        rows: [StaticShortcut("right-click the menu bar", "system ↔ last curve")]
                    )
                ]
            )
            .frame(width: 640, height: 560),
            size: NSSize(width: 640, height: 560), on: NSApp.keyWindow?.screen)
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
