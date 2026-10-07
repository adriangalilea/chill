import ChillKit
import MachSensors
import SwiftUI

/// What one frame of the plot draws, snapshotted from the model so the
/// renderer closures read values, not observables.
struct Frame {
    /// nil while nothing reported one: the y-axis is not drawn.
    let envelope: ClosedRange<Double>?
    let curve: Curve?
    let point: Int
    let die: Double?
    let actuals: [Double]
    let targets: [Double]
    let trail: Trail
    /// The instant drawn: the timeline's, or the film's (`Model.now`).
    let now: Date

    static let celsius: ClosedRange<Double> = 30...110
}

/// The plot's coordinate map, one for drawing and the pointer alike: °C
/// across, rpm up, y spanning the fans' envelope with a 5% margin.
struct PlotGeometry {
    let plot: CGRect
    let yLo: Double
    let yHi: Double

    static let inset = EdgeInsets(top: 12, leading: 48, bottom: 28, trailing: 12)

    init?(size: CGSize, envelope: ClosedRange<Double>?) {
        plot = CGRect(
            x: PlotGeometry.inset.leading, y: PlotGeometry.inset.top,
            width: size.width - PlotGeometry.inset.leading - PlotGeometry.inset.trailing,
            height: size.height - PlotGeometry.inset.top - PlotGeometry.inset.bottom)
        guard plot.width > 0, plot.height > 0, let envelope else { return nil }
        let span = envelope.upperBound - envelope.lowerBound
        yLo = envelope.lowerBound - span * 0.05
        yHi = envelope.upperBound + span * 0.05
    }

    /// Both axes are logarithmic. Temperature: the action lives at the
    /// cool end, and a log gives it room continuously, the grid
    /// tightening smoothly toward the hot end. Rpm: noise grows with the
    /// log of the speed, and the differences that matter are the quiet
    /// ones near the floor. One map and its inverse per axis, used by
    /// everything drawn, hovered or dragged; the heatmap's stops go
    /// through the same map.
    static let logSpan = Foundation.log(Frame.celsius.upperBound / Frame.celsius.lowerBound)

    /// 0 to 1 across the temperature axis.
    static func unit(_ c: Double) -> Double {
        let c = min(Frame.celsius.upperBound, max(Frame.celsius.lowerBound, c))
        return Foundation.log(c / Frame.celsius.lowerBound) / logSpan
    }

    /// The temperature at 0 to 1 across the axis.
    static func celsius(unit u: Double) -> Double {
        Frame.celsius.lowerBound * exp(min(1, max(0, u)) * logSpan)
    }

    func x(_ c: Double) -> CGFloat {
        plot.minX + plot.width * PlotGeometry.unit(c)
    }
    func y(_ rpm: Double) -> CGFloat {
        let r = min(yHi, max(yLo, rpm))
        return plot.maxY - plot.height * Foundation.log(r / yLo) / Foundation.log(yHi / yLo)
    }
    func celsius(at p: CGPoint) -> Double {
        PlotGeometry.celsius(unit: (p.x - plot.minX) / plot.width)
    }
    func rpm(at p: CGPoint) -> Double {
        let u = min(1, max(0, (plot.maxY - p.y) / plot.height))
        return yLo * exp(u * Foundation.log(yHi / yLo))
    }
    /// The curve point under the pointer, within a fingertip.
    func hit(_ curve: Curve?, at p: CGPoint) -> Int? {
        guard let curve else { return nil }
        let distances = curve.points.enumerated().map { i, pt in
            (i, hypot(x(pt.c) - p.x, y(pt.rpm) - p.y))
        }
        return distances.min { $0.1 < $1.1 }.flatMap { $0.1 <= 12 ? $0.0 : nil }
    }
}

/// The afterglow: the path the live point has travelled, recorded by
/// the animated layer itself on every frame it draws, so the trail ends
/// exactly where the point is and moves at its exact pace. A soft
/// blurred stroke in the heat the die had along the way, fading with
/// age like phosphor after the lamp moved on.
final class Trail {
    struct Mark {
        let at: Date
        let die: Double
        let rpm: Double
    }

    private(set) var marks: [Mark] = []

    /// How long a stretch glows.
    static let span: TimeInterval = 25
    /// Below this travel a frame adds no mark (a still point, a jitter).
    static let stepCelsius = 0.15
    static let stepRPM = 8.0

    /// Called from the live layer's draw with the point's animated
    /// position at the instant drawn: appends when it moved, prunes what
    /// has faded.
    func record(die: Double, rpm: Double, at now: Date) {
        marks.removeAll { now.timeIntervalSince($0.at) > Trail.span }
        if let last = marks.last,
            abs(die - last.die) < Trail.stepCelsius, abs(rpm - last.rpm) < Trail.stepRPM
        {
            return
        }
        marks.append(Mark(at: now, die: die, rpm: rpm))
    }

    /// The glow of a stretch at `age`: faint even fresh, falling fast
    /// (cubic), gone at `span`.
    static func alpha(age: TimeInterval) -> Double {
        0.12 * pow(max(0, 1 - age / span), 3)
    }

    /// Something still glows: the timeline keeps ticking to fade it.
    func glowing(at now: Date) -> Bool {
        marks.last.map { now.timeIntervalSince($0.at) < Trail.span } ?? false
    }
}

extension GraphicsContext {
    /// A label that reads anywhere on the plot: the text on a small plate
    /// of the window's own background, so dune over dune and ice over
    /// the lit heatmap keep their contrast. `anchor` places the plate.
    /// `within`: the plate is slid to stay inside it, never clipped;
    /// `flipBelow`: when the plate would cross the top, it is placed the
    /// same distance BELOW the point instead.
    func plated(
        _ text: Text, at point: CGPoint, anchor: UnitPoint = .center, within: CGRect? = nil,
        flipBelow: Bool = false
    ) {
        let resolved = resolve(text)
        let size = resolved.measure(in: CGSize(width: 400, height: 40))
        let pad = CGSize(width: 5, height: 2)
        var plate = CGRect(
            x: point.x - (size.width + 2 * pad.width) * anchor.x,
            y: point.y - (size.height + 2 * pad.height) * anchor.y,
            width: size.width + 2 * pad.width, height: size.height + 2 * pad.height)
        if let within {
            if flipBelow, plate.minY < within.minY {
                plate.origin.y = point.y + (point.y - plate.midY) - plate.height / 2
            }
            plate.origin.x = min(max(plate.minX, within.minX), within.maxX - plate.width)
            plate.origin.y = min(max(plate.minY, within.minY), within.maxY - plate.height)
        }
        fill(
            Path(roundedRect: plate, cornerRadius: 4),
            with: .color(Color(nsColor: .windowBackgroundColor).opacity(0.82)))
        draw(resolved, at: CGPoint(x: plate.midX, y: plate.midY), anchor: .center)
    }
}

/// The live numbers gliding between samples on the plot's own clock:
/// an ease-out over `span` from wherever the last glide was, read at
/// whatever rate the timeline ticks (30 fps), instead of SwiftUI
/// interpolating at the display's rate. Two vectors of different
/// length do not blend (a fan appearing, the die arriving): the glide
/// jumps to the target.
struct Glide {
    static let span: TimeInterval = 0.9
    private var from = Vec.zero
    private var to = Vec.zero
    private var since = Date.distantPast

    /// Below this a sample's change is under a pixel on the plot: the
    /// numbers land without a glide, and a steady machine draws nothing.
    static let deadband = (celsius: 0.3, rpm: 15.0)

    mutating func aim(_ target: Vec, at now: Date = .now) {
        let here = value(at: now)
        let blends = here.v.count == target.v.count && here.v[0] >= 0 && target.v[0] >= 0
        if blends, !moving(at: now), abs(target.v[0] - to.v[0]) < Glide.deadband.celsius,
            zip(target.v.dropFirst(), to.v.dropFirst()).allSatisfy({
                abs($0 - $1) < Glide.deadband.rpm
            })
        {
            to = target
            from = target
            return
        }
        from = blends ? here : target
        to = target
        since = now
    }

    func moving(at now: Date) -> Bool { now.timeIntervalSince(since) < Glide.span }

    func value(at now: Date) -> Vec {
        guard from.v.count == to.v.count, !to.v.isEmpty else { return to }
        let t = min(1, max(0, now.timeIntervalSince(since) / Glide.span))
        var delta = to - from
        delta.scale(by: 1 - (1 - t) * (1 - t))
        return from + delta
    }
}

/// A vector of doubles SwiftUI can interpolate: every live number of the
/// plot in one, so a new sample slides the die, the rings and the curve
/// together. Two vectors of different length do not blend; the layer
/// then draws the truth outright (a point added, a fan appearing).
struct Vec: VectorArithmetic {
    var v: [Double]

    static var zero: Vec { Vec(v: []) }
    static func + (a: Vec, b: Vec) -> Vec { Vec(v: zip(a.v, b.v).map(+)) }
    static func - (a: Vec, b: Vec) -> Vec { Vec(v: zip(a.v, b.v).map(-)) }
    static func += (a: inout Vec, b: Vec) { a = a + b }
    static func -= (a: inout Vec, b: Vec) { a = a - b }
    mutating func scale(by rhs: Double) { v = v.map { $0 * rhs } }
    var magnitudeSquared: Double { v.reduce(0) { $0 + $1 * $1 } }
}

/// The reference cloud under a faint heatmap, the curve, and the live
/// marks: the hottest die as a hairline in its heat's color, revealing
/// the heatmap up to itself; each fan's actual rpm as a dune ring with
/// its name and number; chill's target as a filled dune dot while chill
/// holds the fan. The pointer draws here when the plot is editable: a
/// click lands a point, a drag moves the one under it, a double-click
/// uses the curve. Everything live glides between samples.
struct Plot: View {
    let model: Model
    let curve: Curve?
    let editable: Bool
    @SwiftUI.State private var dragging: Int?
    @SwiftUI.State private var hover: CGPoint?
    /// Where each badge really is, reported by the pinboard after it
    /// measured and clamped it; the hover finds a badge here, not in a
    /// guess. A reference, like `Pointer`: the badges move on every
    /// timeline tick, and a state write per tick would re-run this whole
    /// body 30 times a second for nothing the hover needs until it moves.
    final class Boxes {
        var at: [Hovered: CGRect] = [:]
    }
    @SwiftUI.State private var boxes = Boxes()
    /// The live numbers between samples.
    @SwiftUI.State private var glide = Glide()

    /// The frame with the live numbers where the glide has them now.
    private func glided(_ f: Frame, at date: Date) -> Frame {
        let v = glide.value(at: date).v
        guard v.count == LiveLayer.encode(f).v.count else {
            return Frame(
                envelope: f.envelope, curve: f.curve, point: f.point, die: f.die,
                actuals: f.actuals, targets: f.targets, trail: f.trail, now: date)
        }
        let n = f.actuals.count
        return Frame(
            envelope: f.envelope, curve: f.curve, point: f.point,
            die: v[0] < 0 ? nil : v[0], actuals: Array(v[1..<1 + n]),
            targets: f.targets.isEmpty ? [] : Array(v[1 + n..<1 + 2 * n]), trail: f.trail,
            now: date)
    }
    @SwiftUI.State private var rightClicks: Any?
    /// The pointer's last position in the plot, readable from the
    /// right-click monitor's closure without capturing a stale value.
    @SwiftUI.State private var pointer = Pointer()

    final class Pointer {
        var at: CGPoint?
        var editable = false
    }

    /// How near the line the pointer must be for the ghost point.
    static let ghostReach: CGFloat = 14

    /// Where a point would be born: on the curve at the pointer's
    /// temperature, while the pointer is near the line and not on a
    /// point.
    static func ghost(at p: CGPoint, _ f: Frame, _ g: PlotGeometry) -> Curve.Point? {
        guard let curve = f.curve, g.plot.contains(p), g.hit(curve, at: p) == nil else {
            return nil
        }
        let c = g.celsius(at: p)
        let rpm = curve.rpm(at: c)
        guard abs(g.y(rpm) - p.y) < ghostReach else { return nil }
        return Curve.Point(c: c, rpm: rpm)
    }

    /// On any plot: the point on the curve at the pointer's temperature,
    /// its coordinates said, so a curve can be read per degree. On an
    /// editable plot it is also where a press bears a point.
    private func ghost(_ f: Frame, _ g: PlotGeometry?) -> Curve.Point? {
        guard dragging == nil, let hover, let g else { return nil }
        return Plot.ghost(at: hover, f, g)
    }

    /// Fans closer than this read as one rule; apart, each gets its name.
    static let togetherRPM = 225.0
    /// How near a line the pointer must rest for its card.
    static let hoverReach: CGFloat = 10
    /// The plot's coordinate space, the one the badges report their
    /// frames in.
    nonisolated static let space = "plot"

    /// What the pointer rests on: the die's vertical (line or label), or
    /// a fan's horizontal. The curve wins outright, a point within reach
    /// or the line itself within the ghost's reach: no card, no
    /// highlight, the curve is what the pointer is there for, and a card
    /// opening over it would take it away.
    enum Hovered: Equatable {
        case die, fans
    }

    /// What the pointer rests on, held where it was when the pointer
    /// arrived: the die's temperature or the fans' rpm at that moment. The
    /// live line goes on moving with every sample; the card and the reach
    /// that keeps it open stay put, so a pointer resting on a card is never
    /// left behind by it.
    struct Held: Equatable {
        let on: Hovered
        let at: Double
    }
    @SwiftUI.State private var held: Held?
    /// Where the badges sit, kept between layouts (`Pinboard.Choice`).
    @SwiftUI.State private var spots = Pinboard.Choice()

    /// What the badges should not hide: the curve and its points, each
    /// live point's halo, the die's line, the fans' rules, chill's targets.
    static func clutter(_ f: Frame, _ g: PlotGeometry) -> Pinboard.Clutter {
        var c = Pinboard.Clutter()
        if let curve = f.curve {
            c.traces = CurveLayer.samples.map { CGPoint(x: g.x($0), y: g.y(curve.rpm(at: $0))) }
            c.discs = curve.points.filter { Frame.celsius.contains($0.c) }.map {
                (CGPoint(x: g.x($0.c), y: g.y($0.rpm)), 6)
            }
        }
        let rpms = LiveLayer.marks(f.actuals).map(\.1)
        if let die = f.die {
            c.verticals = [g.x(die)]
            c.discs += rpms.map { (CGPoint(x: g.x(die), y: g.y($0)), 14) }
        }
        c.horizontals = rpms.map(g.y) + f.targets.map(g.y)
        return c
    }

    static func hovered(
        _ p: CGPoint, _ f: Frame, _ g: PlotGeometry, boxes: [Hovered: CGRect], held: Held?
    ) -> Hovered? {
        guard g.plot.contains(p) else { return nil }
        if g.hit(f.curve, at: p) != nil || ghost(at: p, f, g) != nil { return nil }
        if let held {
            switch held.on {
            case .die where abs(p.x - g.x(held.at)) < hoverReach:
                return .die
            case .fans where abs(p.y - g.y(held.at)) < hoverReach:
                return .fans
            default:
                if boxes[held.on]?.contains(p) == true { return held.on }
            }
        }
        if let die = f.die, abs(p.x - g.x(die)) < hoverReach || boxes[.die]?.contains(p) == true {
            return .die
        }
        for rpm in LiveLayer.marks(f.actuals).map(\.1)
        where abs(p.y - g.y(rpm)) < hoverReach || boxes[.fans]?.contains(p) == true {
            return .fans
        }
        return nil
    }

    enum Hand: Equatable {
        case open, closed
    }

    /// A hand over a draggable point or the ghost, closed while dragging.
    private func cursorWants(_ f: Frame, _ g: PlotGeometry?) -> Hand? {
        guard editable, let g else { return nil }
        if let dragging, dragging >= 0 { return .closed }
        guard let hover else { return nil }
        if g.hit(f.curve, at: hover) != nil || Plot.ghost(at: hover, f, g) != nil { return .open }
        return nil
    }

    /// The pointer is on the curve: dragging a point, over one, or on the
    /// line within the ghost's reach.
    private func riding(_ f: Frame, _ g: PlotGeometry) -> Bool {
        if let dragging, dragging >= 0 { return true }
        guard let hover else { return false }
        return g.hit(f.curve, at: hover) != nil || Plot.ghost(at: hover, f, g) != nil
    }

    /// What the pointer rests on right now.
    private func lit(_ f: Frame, _ g: PlotGeometry?) -> Hovered? {
        guard let hover, let g else { return nil }
        return Plot.hovered(hover, f, g, boxes: boxes.at, held: held)
    }

    /// Where a lit card's line was when the pointer reached it.
    private func hold(_ on: Hovered?, _ f: Frame) -> Held? {
        switch on {
        case .die: return f.die.map { Held(on: .die, at: $0) }
        case .fans: return LiveLayer.marks(f.actuals).first.map { Held(on: .fans, at: $0.1) }
        case nil: return nil
        }
    }

    /// While the pointer is on one thing, the other labels recede, so the
    /// one it is on reads whole however crowded the plot is.
    private func dimmed(_ on: Hovered, _ f: Frame, _ g: PlotGeometry) -> Bool {
        if riding(f, g) { return true }
        guard let lit = lit(f, g) else { return false }
        return lit != on
    }

    init(model: Model, curve: Curve?, editable: Bool) {
        self.model = model
        self.curve = curve
        self.editable = editable
    }

    var body: some View {
        let frame = Frame(
            envelope: model.envelope, curve: curve,
            point: editable ? model.point : -1, die: model.die, actuals: model.actuals,
            targets: model.targets, trail: model.trail, now: model.now(.now))
        GeometryReader { proxy in
            let geometry = PlotGeometry(size: proxy.size, envelope: frame.envelope)
            ZStack {
                Canvas { context, _ in
                    if let geometry { Plot.drawStatic(frame, geometry, in: context) }
                }
                if let geometry, let curve = frame.curve {
                    CurveLayer(
                        curve: curve, point: frame.point, geometry: geometry,
                        // Under the pointer a point rings and says its
                        // numbers on every plot; only moving it is the
                        // editable plot's.
                        hot: dragging.flatMap { $0 >= 0 ? $0 : nil }
                            ?? hover.flatMap { geometry.hit(curve, at: $0) },
                        ghost: ghost(frame, geometry), editable: editable,
                        heldNote: dragging.flatMap { i in
                            i >= 0 && curve.points.indices.contains(i)
                                ? model.heldNote(curve.points[i]) : nil
                        }
                    )
                    .animation(.easeOut(duration: 0.5), value: CurveLayer.encode(curve))
                    .transition(.opacity)
                    // Riding the curve, the curve is on top of everything:
                    // its label and points over the live marks and the
                    // badges, never under them.
                    .zIndex(riding(frame, geometry) ? 4 : 1)
                }
                // The live numbers glide on the plot's own clock: a 30 fps
                // timeline, paused once the glide is done and the afterglow
                // has faded, instead of SwiftUI interpolating at the
                // display's rate (120 Hz here) through every sample. The
                // layer and the badges read the same glided frame.
                if let geometry {
                    let lit = lit(frame, geometry)
                    // 24 fps while the numbers glide (a 0.9 s ease over a
                    // few points of travel needs no more); 10 while only
                    // the afterglow fades; paused once nothing moves and
                    // nothing glows.
                    TimelineView(
                        .animation(
                            minimumInterval: glide.moving(at: .now) ? 1.0 / 24 : 1.0 / 10,
                            paused: !glide.moving(at: .now) && !frame.trail.glowing(at: .now))
                    ) { timeline in
                        let live = glided(frame, at: model.now(timeline.date))
                        ZStack {
                            // A fresh identity whenever the live numbers
                            // appear or vanish: the layer is born at the truth
                            // and fades in, never swept in from nothing.
                            LiveLayer(frame: live, geometry: geometry, lit: lit)
                                .id(frame.die != nil && !frame.actuals.isEmpty)
                                .transition(.opacity)
                                .zIndex(2)
                            // The labels are badges: one view each on the
                            // pinboard, which places each beside its mark for
                            // the size it has right now and keeps it inside the
                            // plot, so the same view expands under the pointer
                            // and shrinks back in place, its anchored edge
                            // still, never past an edge. Each has a few spots
                            // along its own line and the board takes the ones
                            // that hide the least of the plot and of each
                            // other; while the pointer is on one, both stay.
                            // The expanded one is on top of the other.
                            Pinboard(
                                clutter: Plot.clutter(live, geometry),
                                choice: spots, frozen: held != nil
                            ) {
                                if let live = live.die {
                                    let die = held?.on == .die ? held!.at : live
                                    let right = LiveLayer.dieLabelRight(die, geometry)
                                    let x = geometry.x(die)
                                    let plot = geometry.plot
                                    Badge(
                                        model: model, frame: frame, on: .die, expanded: lit == .die
                                    )
                                    .fixedSize()
                                    .opacity(dimmed(.die, frame, geometry) ? 0.3 : 1)
                                    .placed { boxes.at[.die] = $0 }
                                    .zIndex(lit == .die ? 1 : 0)
                                    // At the top of its line, on the side with
                                    // room or the other: never far from where
                                    // the eye already found it.
                                    .pinned(among: { size in
                                        let near = right ? x + 6 : x - 6 - size.width
                                        let far = right ? x - 6 - size.width : x + 6
                                        return [
                                            CGPoint(x: near, y: plot.minY - 2),
                                            CGPoint(x: far, y: plot.minY - 2),
                                        ]
                                    })
                                }
                                if let lead = LiveLayer.marks(live.actuals).first?.1 {
                                    let rpm = held?.on == .fans ? held!.at : lead
                                    let y = geometry.y(rpm)
                                    let plot = geometry.plot
                                    Badge(
                                        model: model, frame: frame, on: .fans,
                                        expanded: lit == .fans
                                    )
                                    .fixedSize()
                                    .opacity(dimmed(.fans, frame, geometry) ? 0.3 : 1)
                                    .placed { boxes.at[.fans] = $0 }
                                    .zIndex(lit == .fans ? 1 : 0)
                                    // On its rule, above or below it, at
                                    // the right end or the left.
                                    .pinned(among: { size in
                                        let xs = [plot.maxX - 4 - size.width, plot.minX + 4]
                                        return xs.flatMap { x in
                                            [
                                                CGPoint(x: x, y: y - 3 - size.height),
                                                CGPoint(x: x, y: y + 3),
                                            ]
                                        }
                                    })
                                }
                            }
                            .allowsHitTesting(false)
                            .zIndex(3)
                        }
                    }
                    .zIndex(2)
                }
            }
            .coordinateSpace(.named(Plot.space))
            .onChange(of: LiveLayer.encode(frame), initial: true) { _, target in
                glide.aim(target, at: frame.now)
            }
            .animation(.inkSettle, value: lit(frame, geometry))
            // Held from the moment the pointer reaches a card until it
            // leaves it; a move from one card to the other holds the other.
            .onChange(of: lit(frame, geometry)) { _, now in
                held = now == held?.on ? held : hold(now, frame)
            }
            .animation(.inkSettle, value: frame.curve?.name)
            .animation(.inkSettle, value: frame.die != nil && !frame.actuals.isEmpty)
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    hover = p
                    pointer.at = p
                case .ended: hover = nil
                }
            }
            // The cursor says it too: a hand over a point, closed while
            // it drags.
            .onChange(of: cursorWants(frame, geometry)) { _, hand in
                switch hand {
                case .open: NSCursor.openHand.set()
                case .closed: NSCursor.closedHand.set()
                case .none: NSCursor.arrow.set()
                }
            }
            .contentShape(Rectangle())
            // One motion: press a point (or the ghost on the line, which
            // becomes a point at the press), drag it, release, it stays.
            // Empty plot does nothing.
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard let geometry else { return }
                        if dragging == nil {
                            if let hit = geometry.hit(frame.curve, at: value.startLocation) {
                                dragging = hit
                            } else if let born = Plot.ghost(
                                at: value.startLocation, frame, geometry)
                            {
                                model.place(celsius: born.c, rpm: born.rpm)
                                dragging =
                                    model.editing?.points.firstIndex { $0.c == born.c.rounded() }
                                    ?? -1
                            } else {
                                dragging = -1
                            }
                        }
                        guard let index = dragging, index >= 0 else { return }
                        model.point = index
                        model.drag(
                            index, celsius: geometry.celsius(at: value.location),
                            rpm: geometry.rpm(at: value.location))
                    }
                    .onEnded { _ in dragging = nil },
                including: editable ? .all : .none
            )
            // Right-click on a point removes it: an event monitor, since
            // SwiftUI gestures do not see the secondary button.
            .onChange(of: editable, initial: true) { _, on in pointer.editable = on }
            .onAppear {
                // A film renders a fresh plot per frame and has no pointer.
                guard !model.filming else { return }
                // Installed once for the view's life (onAppear fires once,
                // whichever tab was up), so whether the plot is editable
                // right now is read from the box, never captured. The
                // pointer is where the last hover put it, in the plot's
                // own space: no window arithmetic; curve and geometry are
                // read live.
                rightClicks = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) {
                    event in
                    guard pointer.editable else { return event }
                    guard let p = pointer.at,
                        let g = PlotGeometry(size: proxy.size, envelope: model.envelope)
                    else {
                        log.debug("right-click: pointer unknown or no geometry")
                        return event
                    }
                    guard let hit = g.hit(model.editing, at: p) else {
                        log.debug("right-click at \(Int(p.x)),\(Int(p.y)): no point in reach")
                        return event
                    }
                    log.info("right-click: removing point \(hit)")
                    model.point = hit
                    model.removePoint()
                    return nil
                }
            }
            .onDisappear {
                if let rightClicks { NSEvent.removeMonitor(rightClicks) }
                rightClicks = nil
            }
            .simultaneousGesture(
                TapGesture(count: 2).onEnded {
                    if let editing = model.editing { model.use(editing) }
                },
                including: editable ? .all : .none
            )
        }
        .background(
            RoundedRectangle(cornerRadius: .inkField).fill(Color.inkRest.opacity(0.4))
        )
    }

    /// The grid and the heatmap at rest.
    private static func drawStatic(_ f: Frame, _ g: PlotGeometry, in context: GraphicsContext) {
        let plot = g.plot
        var faint = context
        faint.opacity = 0.07
        faint.fill(
            Path(plot),
            with: .linearGradient(
                Palette.heatGradient, startPoint: CGPoint(x: plot.minX, y: plot.midY),
                endPoint: CGPoint(x: plot.maxX, y: plot.midY)))

        // A log chart's grid is even; the values on it are what run
        // geometric. Eight columns and five rows at equal spacing, each
        // labelled with the temperature or rpm found there.
        let hair = GraphicsContext.Shading.color(.primary.opacity(0.07))
        let columns = 8
        for i in 0...columns {
            let u = Double(i) / Double(columns)
            let x = plot.minX + plot.width * u
            var line = Path()
            line.move(to: CGPoint(x: x, y: plot.minY))
            line.addLine(to: CGPoint(x: x, y: plot.maxY))
            context.stroke(line, with: hair, lineWidth: 1)
            context.draw(
                Text("\(Int(PlotGeometry.celsius(unit: u).rounded()))°").font(.meta)
                    .foregroundStyle(.tertiary),
                at: CGPoint(x: x, y: plot.maxY + 14))
        }
        let rows = 5
        for i in 0...rows {
            let u = Double(i) / Double(rows)
            let y = plot.maxY - plot.height * u
            var line = Path()
            line.move(to: CGPoint(x: plot.minX, y: y))
            line.addLine(to: CGPoint(x: plot.maxX, y: y))
            context.stroke(line, with: hair, lineWidth: 1)
            let rpm = g.rpm(at: CGPoint(x: plot.minX, y: y))
            context.draw(
                Text("\(Int((rpm / 100).rounded() * 100))").font(.meta).foregroundStyle(.tertiary),
                at: CGPoint(x: plot.minX - 24, y: y))
        }
    }
}

/// The curve, its own layer: it fades in and out with the tab, and
/// morphs while a knob or a drag moves its points (a point added or
/// removed changes the vector's length and lands at once).
struct CurveLayer: View, @MainActor Animatable {
    let curve: Curve
    let point: Int
    let geometry: PlotGeometry
    var vec: Vec

    /// The point under the pointer: it grows and rings, the sign that it
    /// can be dragged.
    let hot: Int?
    /// Why the hot point stopped short of the pointer, if it did.
    let heldNote: String?
    /// Where a press would put a new point: hollow, on the line, following
    /// the pointer.
    let ghost: Curve.Point?

    /// Whether a press on the probe bears a point (the probe's dash).
    let editable: Bool

    init(
        curve: Curve, point: Int, geometry: PlotGeometry, hot: Int?, ghost: Curve.Point?,
        editable: Bool, heldNote: String?
    ) {
        self.curve = curve
        self.point = point
        self.geometry = geometry
        self.hot = hot
        self.ghost = ghost
        self.editable = editable
        self.heldNote = heldNote
        vec = CurveLayer.encode(curve)
    }

    var animatableData: Vec {
        get { vec }
        set { vec = newValue }
    }

    /// The curve as the plot draws it: its rpm at every half degree of
    /// the axis, always the same length, so ANY curve morphs into any
    /// other (a three-point S into gust's flat ceiling included), then
    /// the points' own coordinates, which only blend while the count
    /// holds (the rest of the vector still does).
    static let samples = stride(
        from: Frame.celsius.lowerBound, through: Frame.celsius.upperBound, by: 0.5
    ).map { $0 }

    static func encode(_ curve: Curve) -> Vec {
        Vec(v: samples.map(curve.rpm(at:)) + curve.points.flatMap { [$0.c, $0.rpm] })
    }

    var body: some View {
        Canvas { context, _ in draw(in: context) }
    }

    /// The line from the animated samples; a soft fill under it; the
    /// points from their animated coordinates while the count holds,
    /// from the truth otherwise; the selected point ringed and labelled
    /// below the line.
    private func draw(in context: GraphicsContext) {
        let g = geometry
        let plot = g.plot
        let n = CurveLayer.samples.count
        let rpms = vec.v.count >= n ? Array(vec.v[0..<n]) : CurveLayer.samples.map(curve.rpm(at:))
        var points = curve.points
        if vec.v.count == n + curve.points.count * 2 {
            points = (0..<curve.points.count).map {
                Curve.Point(c: vec.v[n + $0 * 2], rpm: vec.v[n + $0 * 2 + 1])
            }
        }
        var line = Path()
        line.move(to: CGPoint(x: plot.minX, y: g.y(rpms[0])))
        for (c, rpm) in zip(CurveLayer.samples, rpms) {
            line.addLine(to: CGPoint(x: g.x(c), y: g.y(rpm)))
        }
        var under = line
        under.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY))
        under.addLine(to: CGPoint(x: plot.minX, y: plot.maxY))
        under.closeSubpath()
        context.fill(under, with: .color(Palette.dune.opacity(0.08)))
        context.stroke(
            line, with: .color(Palette.dune.opacity(0.95)),
            style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        // The probe: on the line at the pointer's temperature, its
        // coordinates above it. Dashed where a press would bear a point,
        // solid where the curve is only read.
        if let ghost {
            let dot = CGRect(x: g.x(ghost.c) - 5, y: g.y(ghost.rpm) - 5, width: 10, height: 10)
            context.fill(
                Path(ellipseIn: dot), with: .color(Color(nsColor: .windowBackgroundColor)))
            context.stroke(
                Path(ellipseIn: dot), with: .color(Palette.dune),
                style: StrokeStyle(lineWidth: 1.5, dash: editable ? [2, 2] : []))
            context.plated(
                Text("\(Int(ghost.c.rounded()))° → \(Int(ghost.rpm.rounded())) rpm").font(.meta)
                    .foregroundStyle(Palette.dune),
                at: CGPoint(x: g.x(ghost.c), y: g.y(ghost.rpm) - 18), within: plot,
                flipBelow: true)
        }
        // A flat curve (gust) has one point at 0 °C, off the axis: no dot.
        for (i, p) in points.enumerated() where Frame.celsius.contains(p.c) {
            // A dark edge lifts the point off the line and off the live
            // point's dune; the selected one is ringed and labelled to
            // its upper right, clear of the live point's halo.
            // Only the pointer changes a point's look: under it (or
            // dragged by it) the point grows, rings and shows its
            // numbers; the keyboard's selection has no look of its own.
            let r: CGFloat = i == hot ? 6 : 4
            let dot = CGRect(x: g.x(p.c) - r, y: g.y(p.rpm) - r, width: r * 2, height: r * 2)
            context.fill(Path(ellipseIn: dot), with: .color(Palette.dune))
            context.stroke(
                Path(ellipseIn: dot), with: .color(Color(nsColor: .windowBackgroundColor)),
                lineWidth: 1.5)
            if i == hot {
                // The ring is the handle: only where the point can be
                // moved, so a read-only curve never looks grabbable.
                if editable {
                    context.stroke(
                        Path(ellipseIn: dot.insetBy(dx: -4, dy: -4)),
                        with: .color(Palette.dune.opacity(0.6)), lineWidth: 1.5)
                }
                // Held at a neighbour's rpm, the label says so: the
                // point stopped, the pointer did not.
                let note = heldNote.map { " · \($0)" } ?? ""
                context.plated(
                    Text("\(Int(p.c))° · \(Int(p.rpm)) rpm\(note)").font(.meta)
                        .foregroundStyle(note.isEmpty ? Palette.dune : Palette.ember),
                    at: CGPoint(x: g.x(p.c) + 14, y: g.y(p.rpm) - 18), anchor: .leading,
                    within: plot, flipBelow: true)
            }
        }
    }
}

/// The live half of the plot: the die, the fans, chill's targets. Its
/// animatable data is a vector of fixed length, so every new sample and
/// every change of intent glides.
struct LiveLayer: View {
    /// The frame as the glide has it now: drawn as given, on the
    /// timeline's ticks, never interpolated here.
    let frame: Frame
    let geometry: PlotGeometry

    /// The element under the pointer, drawn brighter: the affordance
    /// that says a card is one rest away.
    let lit: Plot.Hovered?

    /// One rule per fan, or one for both while they run within
    /// `Plot.togetherRPM` of each other.
    static func marks(_ actuals: [Double]) -> [(String, Double)] {
        let spread = (actuals.max() ?? 0) - (actuals.min() ?? 0)
        return actuals.count > 1 && spread <= Plot.togetherRPM
            ? [("fans", actuals.reduce(0, +) / Double(actuals.count))]
            : actuals.enumerated().map { ("fan \($0.offset + 1)", $0.element) }
    }

    /// The glow's three strokes, wide and faint to narrow and full: the
    /// look of a 2.5 pt blur on a 4 pt stroke without the layer.
    static let glow: [(width: CGFloat, share: Double)] = [(9, 0.2), (6, 0.35), (3.5, 0.6)]

    /// The die's label sits right of its line unless the edge is near.
    static func dieLabelRight(_ die: Double, _ g: PlotGeometry) -> Bool {
        g.plot.maxX - g.x(die) > 90
    }

    /// [die or -1000] + actuals + one target per fan (the actual itself
    /// while chill holds nothing, so the length never changes with the
    /// intent and every switch glides). What the glide interpolates.
    static func encode(_ f: Frame) -> Vec {
        var v = [f.die ?? -1000]
        v += f.actuals
        v += f.targets.isEmpty ? f.actuals : f.targets
        return Vec(v: v)
    }

    var body: some View {
        Canvas { context, _ in draw(in: context) }
    }

    private func draw(in context: GraphicsContext) {
        var context = context
        let g = geometry
        let plot = g.plot
        // Nothing live is drawn outside the plot, whatever a value does.
        context.clip(to: Path(plot))
        let die = frame.die
        let actuals = frame.actuals
        let targets = frame.targets

        // The heatmap, revealed up to the die.
        if let die {
            let lit = CGRect(
                x: plot.minX, y: plot.minY, width: max(0, g.x(die) - plot.minX), height: plot.height
            )
            var glow = context
            glow.opacity = 0.25
            glow.fill(
                Path(lit),
                with: .linearGradient(
                    Palette.heatGradient, startPoint: CGPoint(x: plot.minX, y: plot.midY),
                    endPoint: CGPoint(x: plot.maxX, y: plot.midY)))
        }

        // The die: a hairline in its heat's color, labelled at the top.
        // On it, each fan's actual as a dune ring with name and number,
        // labels stacked outward so two fans a few hundred rpm apart stay
        // readable; chill's targets as filled dune dots.
        if let die {
            let heat = Palette.heat(die)
            // Lit: the reach around the line is a faint band, the area
            // the pointer can leave before the card closes.
            if lit == .die {
                context.fill(
                    Path(
                        CGRect(
                            x: g.x(die) - Plot.hoverReach, y: plot.minY,
                            width: Plot.hoverReach * 2, height: plot.height)),
                    with: .color(heat.opacity(0.1)))
            }
            var line = Path()
            line.move(to: CGPoint(x: g.x(die), y: plot.minY))
            line.addLine(to: CGPoint(x: g.x(die), y: plot.maxY))
            context.stroke(
                line, with: .color(heat.opacity(lit == .die ? 1 : 0.7)),
                lineWidth: lit == .die ? 2 : 1)
            // Right of the line, or left of it near the right edge.
            // The label, unless it is the card right now.
            // The die is a vertical hairline, so a fan is a horizontal
            // one at its rpm, the two crossing at the live point, a small
            // ring there. Fans running together are one line, "fans · N
            // rpm"; only a real spread names them apart. The hover card
            // has the exact numbers either way.
            let marks = LiveLayer.marks(actuals)
            // The afterglow: this frame's animated position joins the
            // path, then the path is stroked stretch by stretch in the
            // heat it had, oldest faintest. The glow is three strokes of
            // falling width and alpha, not a blur filter: a blur means an
            // offscreen layer composited on every frame of every sample's
            // animation, and this plot animates at the display's rate;
            // three round strokes read the same and cost a path each.
            // Only positions inside the plot join the afterglow.
            if let lead = marks.first, Frame.celsius.contains(die), g.yLo...g.yHi ~= lead.1 {
                frame.trail.record(die: die, rpm: lead.1, at: frame.now)
            }
            let now = frame.now
            let path = frame.trail.marks
            if path.count > 1 {
                for (a, b) in zip(path, path.dropFirst()) {
                    let alpha = Trail.alpha(age: now.timeIntervalSince(b.at))
                    guard alpha > 0.005 else { continue }
                    var stretch = Path()
                    stretch.move(to: CGPoint(x: g.x(a.die), y: g.y(a.rpm)))
                    stretch.addLine(to: CGPoint(x: g.x(b.die), y: g.y(b.rpm)))
                    let heat = Palette.heat(b.die)
                    for (width, share) in LiveLayer.glow {
                        context.stroke(
                            stretch, with: .color(heat.opacity(alpha * share)),
                            style: StrokeStyle(lineWidth: width, lineCap: .round))
                    }
                }
            }
            for (i, mark) in marks.enumerated() {
                if lit == .fans {
                    context.fill(
                        Path(
                            CGRect(
                                x: plot.minX, y: g.y(mark.1) - Plot.hoverReach,
                                width: plot.width, height: Plot.hoverReach * 2)),
                        with: .color(Palette.dune.opacity(0.1)))
                }
                var rule = Path()
                rule.move(to: CGPoint(x: plot.minX, y: g.y(mark.1)))
                rule.addLine(to: CGPoint(x: plot.maxX, y: g.y(mark.1)))
                context.stroke(
                    rule, with: .color(Palette.dune.opacity(lit == .fans ? 1 : 0.7)),
                    lineWidth: lit == .fans ? 2 : 1)
                // The live point: a soft halo in the die's heat, wide
                // enough to read over the rules and the heatmap, and a
                // small dune core.
                let center = CGPoint(x: g.x(die), y: g.y(mark.1))
                let halo = CGRect(x: center.x - 14, y: center.y - 14, width: 28, height: 28)
                context.fill(
                    Path(ellipseIn: halo),
                    with: .radialGradient(
                        Gradient(colors: [heat.opacity(0.55), heat.opacity(0)]),
                        center: center, startRadius: 0, endRadius: 14))
                // The core wears the heat itself with a light edge: never
                // dune, so it reads apart from a curve point on top of it.
                let core = CGRect(x: center.x - 3.5, y: center.y - 3.5, width: 7, height: 7)
                context.fill(Path(ellipseIn: core), with: .color(heat))
                context.stroke(
                    Path(ellipseIn: core.insetBy(dx: -0.75, dy: -0.75)),
                    with: .color(.white.opacity(0.85)), lineWidth: 1.5)
                let dy: CGFloat = marks.count > 1 && i == 1 ? 9 : -9
                // The lead fan's label is the badge above; a second,
                // split fan keeps its own plate below its rule.
                if i > 0 {
                    context.plated(
                        Text("\(mark.0) · \(Int(mark.1)) rpm").font(.meta)
                            .foregroundStyle(Palette.dune),
                        at: CGPoint(x: plot.maxX - 4, y: g.y(mark.1) + dy), anchor: .trailing,
                        within: plot)
                }
            }
            // chill's target, a dashed rule at the rpm it asked for.
            for target in targets {
                var rule = Path()
                rule.move(to: CGPoint(x: plot.minX, y: g.y(target)))
                rule.addLine(to: CGPoint(x: plot.maxX, y: g.y(target)))
                context.stroke(
                    rule, with: .color(Palette.dune.opacity(0.5)),
                    style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
            }
        }
    }
}

/// The exact numbers, shown while the pointer rests on the die's column:
/// the die to a tenth, each fan's actual, target and holder, who holds
/// the fans. A thin mono card, nothing to click.
/// A label on the plot that is also its own card: the one line at rest,
/// the details under it when the pointer is on its line, the same view
/// growing and shrinking in place.
/// Where a pinboard child may put its top-left, for the size it has: one
/// spot, or several in order of preference, the board picking among them.
struct Pin: LayoutValueKey {
    static let defaultValue: @Sendable (CGSize) -> [CGPoint] = { _ in [.zero] }
}

extension View {
    /// The OUTERMOST modifier on a pinboard child: `onGeometryChange`
    /// between the value and the layout drops it (verified), and the
    /// child then lands at the origin.
    func pinned(_ origin: @escaping @Sendable (CGSize) -> CGPoint) -> some View {
        layoutValue(key: Pin.self, value: { [origin($0)] })
    }

    /// Several spots, best first: the board puts the child in the one
    /// that covers the least of what is drawn (`Pinboard.Clutter`) and of
    /// the other children. Outermost, as `pinned`.
    func pinned(among spots: @escaping @Sendable (CGSize) -> [CGPoint]) -> some View {
        layoutValue(key: Pin.self, value: spots)
    }

    /// The frame this view ended up with, in the plot's space: the truth
    /// the hover reads.
    func placed(_ report: @escaping (CGRect) -> Void) -> some View {
        onGeometryChange(for: CGRect.self) {
            $0.frame(in: .named(Plot.space))
        } action: {
            report($0)
        }
    }
}

/// Places each child where it asks to be for its own size, measured in
/// the same pass, and clamps it into the bounds: a badge that grows
/// past an edge slides in instead of leaving, its anchored edge still,
/// with no frame of lag between growing and moving. A layout, not a
/// stack of offsets, because only a layout sees a child's size before
/// placing it.
///
/// A child with several spots goes where it covers the least: every
/// combination of the children's spots is scored against the clutter (what
/// is drawn under them) and against each other, and the cheapest wins. A
/// label stays in its spot while it hides nothing that matters
/// (`Choice.tolerable`); forced off it, as few labels move as can
/// (`Choice.move`); and none moves while `frozen` (the pointer is on one).
struct Pinboard: Layout {
    /// What the children should not cover, in the board's own space.
    struct Clutter {
        /// Lines drawn as points close together (the curve every half
        /// degree): each one under a child costs `Cost.trace`.
        var traces: [CGPoint] = []
        /// Marks (a curve point, the live point's halo).
        var discs: [(center: CGPoint, radius: CGFloat)] = []
        /// Rules across the plot, vertical at an x or horizontal at a y,
        /// that a child should rather not sit across.
        var verticals: [CGFloat] = []
        var horizontals: [CGFloat] = []
    }

    /// The pick, kept between layouts: a reference, since a layout has no
    /// state of its own across passes.
    /// Unchecked: SwiftUI runs layout on the main thread only, the one
    /// place this is read or written.
    final class Choice: @unchecked Sendable {
        var spots: [Int] = []
        /// Below this the labels stay put: a stretch of curve under one,
        /// a rule's end. Above it something real is hidden: the other
        /// label, a live point, a curve point, most of a label's width
        /// of curve.
        static let tolerable: CGFloat = 400
        /// What each label that changes spot adds to a combination.
        static let move: CGFloat = 250
    }

    /// The cost of covering each kind of clutter; children overlapping
    /// each other cost the most, a label hiding a label being the failure.
    enum Cost {
        static let trace: CGFloat = 20
        static let discArea: CGFloat = 0.6
        static let rule: CGFloat = 80
        static let overlapArea: CGFloat = 3
        /// Each step down a child's own order of preference.
        static let rank: CGFloat = 8
    }

    var clutter = Clutter()
    var choice: Choice?
    var frozen = false

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        // The board's width is proposed, so a child that wraps (a tip
        // capped at some width) is measured wrapped and its plate holds its
        // text; a child that must not stretch says so with `fixedSize`.
        let proposal = ProposedViewSize(width: bounds.width, height: nil)
        let local = CGRect(origin: .zero, size: bounds.size)
        // Every child's spots as rects in the board's space, each slid
        // inside it: a label that grows past an edge slides in instead of
        // leaving, its anchored edge still.
        let spots: [[CGRect]] = subviews.map { subview in
            let size = subview.sizeThatFits(proposal)
            return subview[Pin.self](size).map { wanted in
                CGRect(
                    x: min(max(wanted.x, local.minX), max(local.minX, local.maxX - size.width)),
                    y: min(max(wanted.y, local.minY), max(local.minY, local.maxY - size.height)),
                    width: size.width, height: size.height)
            }
        }
        let picked = pick(spots)
        choice?.spots = picked
        for (subview, (options, i)) in zip(subviews, zip(spots, picked)) {
            let rect = options[i]
            subview.place(
                at: CGPoint(x: bounds.minX + rect.minX, y: bounds.minY + rect.minY),
                anchor: .topLeading, proposal: proposal)
        }
    }

    /// The combination of spots that covers the least.
    private func pick(_ spots: [[CGRect]]) -> [Int] {
        let kept = choice.map(\.spots) ?? []
        let valid =
            kept.count == spots.count && zip(kept, spots).allSatisfy { $0.0 < $0.1.count }
        if valid, frozen { return kept }
        guard spots.contains(where: { $0.count > 1 }) else { return spots.map { _ in 0 } }
        // What a combination hides: the clutter under each label and the
        // labels under each other.
        func hidden(_ combo: [Int]) -> CGFloat {
            var cost = zip(spots, combo).reduce(CGFloat(0)) { $0 + covered($1.0[$1.1]) }
            for i in combo.indices {
                for j in combo.indices where j > i {
                    let both = spots[i][combo[i]].intersection(spots[j][combo[j]])
                    if !both.isNull { cost += both.width * both.height * Cost.overlapArea }
                }
            }
            return cost
        }
        // Labels stay where they are while that hides nothing that
        // matters: a label that moves because another spot became a little
        // emptier is a label that never stops moving.
        if valid, hidden(kept) < Choice.tolerable { return kept }
        var best: (cost: CGFloat, at: [Int])?
        var combo = spots.map { _ in 0 }
        while true {
            var cost = hidden(combo) + combo.reduce(CGFloat(0)) { $0 + CGFloat($1) * Cost.rank }
            // Forced to move, as few labels as can: each that leaves its
            // spot pays for it, so one gives way and the other stays.
            if valid {
                cost += CGFloat(zip(combo, kept).filter { $0 != $1 }.count) * Choice.move
            }
            if best == nil || cost < best!.cost { best = (cost, combo) }
            // The next combination, odometer style.
            var k = combo.count - 1
            while k >= 0 {
                combo[k] += 1
                if combo[k] < spots[k].count { break }
                combo[k] = 0
                k -= 1
            }
            if k < 0 { break }
        }
        return best!.at
    }

    /// What a label at `rect` would hide, plus a little air around it.
    private func covered(_ rect: CGRect) -> CGFloat {
        let r = rect.insetBy(dx: -3, dy: -3)
        var cost = CGFloat(clutter.traces.filter(r.contains).count) * Cost.trace
        for disc in clutter.discs {
            let box = CGRect(
                x: disc.center.x - disc.radius, y: disc.center.y - disc.radius,
                width: disc.radius * 2, height: disc.radius * 2
            ).intersection(r)
            if !box.isNull { cost += box.width * box.height * Cost.discArea }
        }
        cost += CGFloat(clutter.verticals.filter { $0 > r.minX && $0 < r.maxX }.count) * Cost.rule
        cost +=
            CGFloat(clutter.horizontals.filter { $0 > r.minY && $0 < r.maxY }.count) * Cost.rule
        return cost
    }
}

struct Badge: View {
    let model: Model
    let frame: Frame
    let on: Plot.Hovered
    let expanded: Bool

    /// The sensors whose name means something, said plainly. `PMU tcal`
    /// is a calibration reference, not a part; the die's spots are the
    /// strip.
    struct Named: Hashable {
        let name: String
        let celsius: Double
    }

    static func named(_ sensors: [Sensor]) -> [Named] {
        // The HID path lists each sensor several times: one row per
        // name, its hottest.
        var hottest: [String: Double] = [:]
        for s in sensors {
            let name: String
            if s.name.hasPrefix("NAND") {
                name = "ssd"
            } else if s.name.contains("battery") {
                name = "battery"
            } else {
                continue
            }
            hottest[name] = max(hottest[name] ?? -.infinity, s.celsius)
        }
        return ["ssd", "battery"].compactMap { name in
            hottest[name].map { Named(name: name, celsius: $0) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            switch on {
            case .die:
                if let die = frame.die {
                    let source = model.state?.dieSource ?? "die"
                    Text(
                        expanded
                            ? "\(source) \(String(format: "%.1f", die)) °C · what the curve follows"
                            : "\(source) \(Status.degrees(die))"
                    )
                    .foregroundStyle(Palette.heat(die))
                }
                if expanded {
                    // The parts by name: cpu, gpu, memory from their SMC
                    // keys (the hottest sensor of each, and how many),
                    // then ssd and battery from the HID path. Fixed
                    // order, a grid, so nothing trades places.
                    let parts = model.parts()
                    let named = Badge.named(model.temperatures())
                    Grid(alignment: .leading, horizontalSpacing: .inkLane, verticalSpacing: 3) {
                        ForEach(parts, id: \.group) { part in
                            let hottest = part.celsius.max()!
                            GridRow {
                                Text(part.group.rawValue).foregroundStyle(.secondary)
                                Text(String(format: "%.1f °C", hottest))
                                    .foregroundStyle(Palette.heat(hottest))
                                    .gridColumnAlignment(.trailing)
                                Text("hottest of \(part.celsius.count)").foregroundStyle(.tertiary)
                            }
                        }
                        ForEach(named, id: \.name) { part in
                            GridRow {
                                Text(part.name).foregroundStyle(.secondary)
                                Text(String(format: "%.1f °C", part.celsius))
                                    .foregroundStyle(Palette.heat(part.celsius))
                                    .gridColumnAlignment(.trailing)
                                Text("")
                            }
                        }
                    }
                }
            case .fans:
                if let lead = LiveLayer.marks(frame.actuals).first {
                    Text("\(lead.0) · \(Int(lead.1)) rpm").foregroundStyle(Palette.dune)
                }
                if expanded {
                    ForEach(model.fanLines, id: \.self) { line in
                        Text(line).foregroundStyle(Palette.dune)
                    }
                }
            }
        }
        .font(.meta)
        .padding(.horizontal, expanded ? .inkLane : 5)
        .padding(.vertical, expanded ? .inkGap : 2)
        .background(
            Color(nsColor: .windowBackgroundColor).opacity(expanded ? 0.94 : 0.82),
            in: RoundedRectangle(cornerRadius: expanded ? .inkRow : 4)
        )
        .animation(.inkSettle, value: expanded)
    }
}
