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

    static let celsius: ClosedRange<Double> = 30...110
    static let celsiusSpan = celsius.upperBound - celsius.lowerBound
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

    func x(_ c: Double) -> CGFloat {
        plot.minX + plot.width * (c - Frame.celsius.lowerBound) / Frame.celsiusSpan
    }
    func y(_ rpm: Double) -> CGFloat {
        plot.maxY - plot.height * (rpm - yLo) / (yHi - yLo)
    }
    func celsius(at p: CGPoint) -> Double {
        let c = Frame.celsius.lowerBound + (p.x - plot.minX) / plot.width * Frame.celsiusSpan
        return min(Frame.celsius.upperBound, max(Frame.celsius.lowerBound, c))
    }
    func rpm(at p: CGPoint) -> Double {
        let rpm = yLo + (plot.maxY - p.y) / plot.height * (yHi - yLo)
        return min(yHi, max(yLo, rpm))
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
    /// position: appends when it moved, prunes what has faded.
    func record(die: Double, rpm: Double) {
        let now = Date()
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
}

extension GraphicsContext {
    /// A label that reads anywhere on the plot: the text on a small plate
    /// of the window's own background, so dune over dune and ice over
    /// the lit heatmap keep their contrast. `anchor` places the plate.
    func plated(_ text: Text, at point: CGPoint, anchor: UnitPoint = .center) {
        let resolved = resolve(text)
        let size = resolved.measure(in: CGSize(width: 400, height: 40))
        let pad = CGSize(width: 5, height: 2)
        let plate = CGRect(
            x: point.x - (size.width + 2 * pad.width) * anchor.x,
            y: point.y - (size.height + 2 * pad.height) * anchor.y,
            width: size.width + 2 * pad.width, height: size.height + 2 * pad.height)
        fill(
            Path(roundedRect: plate, cornerRadius: 4),
            with: .color(Color(nsColor: .windowBackgroundColor).opacity(0.82)))
        draw(resolved, at: CGPoint(x: plate.midX, y: plate.midY), anchor: .center)
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

    private func ghost(_ f: Frame, _ g: PlotGeometry?) -> Curve.Point? {
        guard editable, dragging == nil, let hover, let g else { return nil }
        return Plot.ghost(at: hover, f, g)
    }

    /// Fans closer than this read as one rule; apart, each gets its name.
    static let togetherRPM = 225.0
    /// How near a line the pointer must rest for its card.
    static let hoverReach: CGFloat = 10

    /// What the pointer rests on: the die's vertical (line or label), or
    /// a fan's horizontal. A curve point within reach wins outright: no
    /// card, no highlight, the point is what the pointer is there for.
    enum Hovered: Equatable {
        case die, fans
    }

    static func hovered(_ p: CGPoint, _ f: Frame, _ g: PlotGeometry, editable: Bool) -> Hovered? {
        guard g.plot.contains(p) else { return nil }
        if editable, g.hit(f.curve, at: p) != nil { return nil }
        if let die = f.die,
            abs(p.x - g.x(die)) < hoverReach || LiveLayer.dieLabelBox(die, g).contains(p)
        {
            return .die
        }
        for rpm in LiveLayer.marks(f.actuals).map(\.1)
        where abs(p.y - g.y(rpm)) < hoverReach || LiveLayer.fanLabelBox(rpm, g).contains(p) {
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

    static func hoveredNow(_ p: CGPoint?, _ f: Frame, _ g: PlotGeometry?, editable: Bool)
        -> Hovered?
    {
        guard let p, let g else { return nil }
        return hovered(p, f, g, editable: editable)
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
            targets: model.targets, trail: model.trail)
        GeometryReader { proxy in
            let geometry = PlotGeometry(size: proxy.size, envelope: frame.envelope)
            ZStack {
                Canvas { context, _ in
                    if let geometry { Plot.drawStatic(frame, geometry, in: context) }
                }
                if let geometry, let curve = frame.curve {
                    CurveLayer(
                        curve: curve, point: frame.point, geometry: geometry,
                        hot: editable
                            ? (dragging.flatMap { $0 >= 0 ? $0 : nil }
                                ?? hover.flatMap { geometry.hit(curve, at: $0) })
                            : nil,
                        ghost: ghost(frame, geometry)
                    )
                    .animation(.easeOut(duration: 0.5), value: CurveLayer.encode(curve))
                    .transition(.opacity)
                }
                if let geometry {
                    LiveLayer(
                        frame: frame, geometry: geometry,
                        lit: Plot.hoveredNow(hover, frame, geometry, editable: editable)
                    )
                    .animation(.easeOut(duration: 0.9), value: LiveLayer.encode(frame))
                }
            }
            // The labels are badges: one view each, pinned by a corner
            // whose offset never depends on their size, so the same view
            // grows into its details under the pointer and shrinks back,
            // in place. The die's badge rides the die's animation.
            .overlay(alignment: .topLeading) {
                if let geometry, let die = frame.die {
                    let lit = Plot.hoveredNow(hover, frame, geometry, editable: editable)
                    let right = LiveLayer.dieLabelRight(die, geometry)
                    Badge(model: model, frame: frame, on: .die, expanded: lit == .die)
                        .fixedSize()
                        .frame(
                            maxWidth: .infinity, maxHeight: .infinity,
                            alignment: right ? .topLeading : .topTrailing
                        )
                        .offset(
                            x: right
                                ? geometry.x(die) + 6
                                : geometry.x(die) - 6 - proxy.size.width,
                            y: geometry.plot.minY - 2
                        )
                        .animation(.easeOut(duration: 0.9), value: die)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if let geometry, let rpm = LiveLayer.marks(frame.actuals).first?.1 {
                    let lit = Plot.hoveredNow(hover, frame, geometry, editable: editable)
                    Badge(model: model, frame: frame, on: .fans, expanded: lit == .fans)
                        .fixedSize()
                        .offset(
                            x: -(proxy.size.width - geometry.plot.maxX + 4),
                            y: -(proxy.size.height - geometry.y(rpm) + 3)
                        )
                        .animation(.easeOut(duration: 0.9), value: rpm)
                        .allowsHitTesting(false)
                }
            }
            .animation(
                .inkSettle, value: Plot.hoveredNow(hover, frame, geometry, editable: editable)
            )
            .animation(.inkSettle, value: frame.curve?.name)
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

        let hair = GraphicsContext.Shading.color(.primary.opacity(0.07))
        for c in stride(from: Frame.celsius.lowerBound, through: Frame.celsius.upperBound, by: 10) {
            var line = Path()
            line.move(to: CGPoint(x: g.x(c), y: plot.minY))
            line.addLine(to: CGPoint(x: g.x(c), y: plot.maxY))
            context.stroke(line, with: hair, lineWidth: 1)
            context.draw(
                Text("\(Int(c))°").font(.meta).foregroundStyle(.tertiary),
                at: CGPoint(x: g.x(c), y: plot.maxY + 14))
        }
        for rpm in stride(from: (g.yLo / 1000).rounded(.up) * 1000, through: g.yHi, by: 1000) {
            var line = Path()
            line.move(to: CGPoint(x: plot.minX, y: g.y(rpm)))
            line.addLine(to: CGPoint(x: plot.maxX, y: g.y(rpm)))
            context.stroke(line, with: hair, lineWidth: 1)
            context.draw(
                Text("\(Int(rpm))").font(.meta).foregroundStyle(.tertiary),
                at: CGPoint(x: plot.minX - 24, y: g.y(rpm)))
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
    /// Where a press would put a new point: hollow, on the line, following
    /// the pointer.
    let ghost: Curve.Point?

    init(curve: Curve, point: Int, geometry: PlotGeometry, hot: Int?, ghost: Curve.Point?) {
        self.curve = curve
        self.point = point
        self.geometry = geometry
        self.hot = hot
        self.ghost = ghost
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
        // The ghost: hollow, on the line, where a press would bear a point.
        if let ghost {
            let dot = CGRect(x: g.x(ghost.c) - 5, y: g.y(ghost.rpm) - 5, width: 10, height: 10)
            context.fill(
                Path(ellipseIn: dot), with: .color(Color(nsColor: .windowBackgroundColor)))
            context.stroke(
                Path(ellipseIn: dot), with: .color(Palette.dune),
                style: StrokeStyle(lineWidth: 1.5, dash: [2, 2]))
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
                context.stroke(
                    Path(ellipseIn: dot.insetBy(dx: -4, dy: -4)),
                    with: .color(Palette.dune.opacity(0.6)), lineWidth: 1.5)
                context.plated(
                    Text("\(Int(p.c))° · \(Int(p.rpm)) rpm").font(.meta)
                        .foregroundStyle(Palette.dune),
                    at: CGPoint(x: g.x(p.c) + 14, y: g.y(p.rpm) - 16), anchor: .leading)
            }
        }
    }
}

/// The live half of the plot: the die, the fans, chill's targets. Its
/// animatable data is a vector of fixed length, so every new sample and
/// every change of intent glides.
struct LiveLayer: View, @MainActor Animatable {
    let frame: Frame
    let geometry: PlotGeometry
    var vec: Vec

    /// The element under the pointer, drawn brighter: the affordance
    /// that says a card is one rest away.
    let lit: Plot.Hovered?

    init(frame: Frame, geometry: PlotGeometry, lit: Plot.Hovered?) {
        self.frame = frame
        self.geometry = geometry
        self.lit = lit
        vec = LiveLayer.encode(frame)
    }

    /// One rule per fan, or one for both while they run within
    /// `Plot.togetherRPM` of each other.
    static func marks(_ actuals: [Double]) -> [(String, Double)] {
        let spread = (actuals.max() ?? 0) - (actuals.min() ?? 0)
        return actuals.count > 1 && spread <= Plot.togetherRPM
            ? [("fans", actuals.reduce(0, +) / Double(actuals.count))]
            : actuals.enumerated().map { ("fan \($0.offset + 1)", $0.element) }
    }

    /// The die's label sits right of its line unless the edge is near.
    static func dieLabelRight(_ die: Double, _ g: PlotGeometry) -> Bool {
        g.plot.maxX - g.x(die) > 90
    }

    static func dieLabelBox(_ die: Double, _ g: PlotGeometry) -> CGRect {
        let x = g.x(die)
        return dieLabelRight(die, g)
            ? CGRect(x: x, y: g.plot.minY, width: 96, height: 20)
            : CGRect(x: x - 96, y: g.plot.minY, width: 96, height: 20)
    }

    static func fanLabelBox(_ rpm: Double, _ g: PlotGeometry) -> CGRect {
        CGRect(x: g.plot.maxX - 120, y: g.y(rpm) - 20, width: 120, height: 40)
    }

    var animatableData: Vec {
        get { vec }
        set { vec = newValue }
    }

    /// [die or -1000] + actuals + targets + the curve's (c, rpm) pairs.
    /// [die or -1000] + actuals + one target per fan (the actual itself
    /// while chill holds nothing, so the length never changes with the
    /// intent and every switch glides).
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
        let g = geometry
        let plot = g.plot
        let truth = LiveLayer.encode(frame)
        let v = vec.v.count == truth.v.count ? vec.v : truth.v
        let die: Double? = v[0] < 0 ? nil : v[0]
        let n = frame.actuals.count
        let actuals = Array(v[1..<1 + n])
        let targets = frame.targets.isEmpty ? [] : Array(v[1 + n..<1 + 2 * n])

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
            // heat it had, blurred into a glow, oldest faintest.
            if let lead = marks.first {
                frame.trail.record(die: die, rpm: lead.1)
            }
            let now = Date()
            let path = frame.trail.marks
            if path.count > 1 {
                context.drawLayer { layer in
                    layer.addFilter(.blur(radius: 2.5))
                    for (a, b) in zip(path, path.dropFirst()) {
                        let alpha = Trail.alpha(age: now.timeIntervalSince(b.at))
                        guard alpha > 0.005 else { continue }
                        var stretch = Path()
                        stretch.move(to: CGPoint(x: g.x(a.die), y: g.y(a.rpm)))
                        stretch.addLine(to: CGPoint(x: g.x(b.die), y: g.y(b.rpm)))
                        layer.stroke(
                            stretch, with: .color(Palette.heat(b.die).opacity(alpha)),
                            style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    }
                }
            }
            for (i, mark) in marks.enumerated() {
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
                        at: CGPoint(x: plot.maxX - 4, y: g.y(mark.1) + dy), anchor: .trailing)
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
        sensors.compactMap { s in
            if s.name.hasPrefix("NAND") { return Named(name: "ssd", celsius: s.celsius) }
            if s.name.contains("battery") { return Named(name: "battery", celsius: s.celsius) }
            return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            switch on {
            case .die:
                if let die = frame.die {
                    Text(
                        expanded
                            ? "die \(String(format: "%.1f", die)) °C"
                            : "die \(Status.degrees(die))"
                    )
                    .foregroundStyle(Palette.heat(die))
                }
                if expanded {
                    // Apple names the die's sensors tdie1…n and says nothing
                    // about what each covers, so no names: how many spots,
                    // how the heat spreads across them (a strip of cells in
                    // fixed order, the hottest ringed), and the sensors
                    // that DO have a name.
                    let all = model.temperatures()
                    let spots = all.filter { $0.name.hasPrefix("PMU tdie") }
                        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                    if let coolest = spots.map(\.celsius).min(),
                        let hottest = spots.map(\.celsius).max()
                    {
                        Text(
                            "\(spots.count) spots on the die · \(String(format: "%.1f", coolest)) to \(String(format: "%.1f", hottest)) °C"
                        )
                        .foregroundStyle(.secondary)
                        HStack(spacing: 2) {
                            ForEach(spots, id: \.name) { spot in
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Palette.heat(spot.celsius))
                                    .frame(width: 12, height: 8)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 2)
                                            .strokeBorder(
                                                spot.celsius == hottest
                                                    ? Color.white.opacity(0.9) : .clear,
                                                lineWidth: 1))
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    ForEach(Badge.named(all), id: \.name) { part in
                        HStack(spacing: .inkGap) {
                            Text(part.name).foregroundStyle(.secondary)
                            Spacer(minLength: .inkLane)
                            Text(String(format: "%.1f °C", part.celsius))
                                .foregroundStyle(Palette.heat(part.celsius))
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
                    Text(frame.targets.isEmpty ? "apple holds the fans" : "chill holds the fans")
                        .foregroundStyle(.secondary)
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
