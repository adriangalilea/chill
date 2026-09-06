import ChillKit
import SwiftUI

/// What one frame of the plot draws, snapshotted from the model so the
/// renderer closures read values, not observables.
struct Frame {
    /// nil while nothing reported one: the y-axis is not drawn.
    let envelope: ClosedRange<Double>?
    let clouds: [Int: [Bin: Int]]
    let curve: Curve?
    let point: Int
    let die: Double?
    let actuals: [Double]
    let targets: [Double]

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

    init(model: Model, curve: Curve?, editable: Bool) {
        self.model = model
        self.curve = curve
        self.editable = editable
    }

    var body: some View {
        let frame = Frame(
            envelope: model.envelope, clouds: model.clouds.bins, curve: curve,
            point: editable ? model.point : -1, die: model.die, actuals: model.actuals,
            targets: model.targets)
        GeometryReader { proxy in
            let geometry = PlotGeometry(size: proxy.size, envelope: frame.envelope)
            ZStack {
                Canvas { context, _ in
                    if let geometry { Plot.drawStatic(frame, geometry, in: context) }
                }
                if let geometry {
                    LiveLayer(frame: frame, geometry: geometry)
                        .animation(.easeOut(duration: 0.9), value: LiveLayer.encode(frame))
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard let geometry else { return }
                        if dragging == nil {
                            dragging = geometry.hit(frame.curve, at: value.startLocation) ?? -1
                        }
                        guard let index = dragging, index >= 0 else { return }
                        model.point = index
                        model.drag(
                            index, celsius: geometry.celsius(at: value.location),
                            rpm: geometry.rpm(at: value.location))
                    }
                    .onEnded { value in
                        defer { dragging = nil }
                        guard let geometry, dragging == -1,
                            hypot(value.translation.width, value.translation.height) < 3
                        else { return }
                        model.place(
                            celsius: geometry.celsius(at: value.location),
                            rpm: geometry.rpm(at: value.location))
                    },
                including: editable ? .all : .none
            )
            .simultaneousGesture(
                TapGesture(count: 2).onEnded {
                    if let editing = model.editing { model.use(editing) }
                },
                including: editable ? .all : .none
            )
        }
        .background(
            RoundedRectangle(cornerRadius: .inkField).fill(Color.inkRest.opacity(0.4)))
    }

    /// The grid, the heatmap at rest, Apple's cloud.
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

        // The cloud: alpha by density, the second fan half as strong.
        for fan in f.clouds.keys.sorted() {
            let table = f.clouds[fan]!
            guard let peak = table.values.max(), peak > 0 else { continue }
            let weight = fan == 0 ? 1.0 : 0.5
            for (bin, count) in table {
                let rect = CGRect(
                    x: g.x(Double(bin.c)), y: g.y(Double(bin.rpm + Cloud.rpmBin)),
                    width: g.x(Double(bin.c) + 1) - g.x(Double(bin.c)),
                    height: g.y(Double(bin.rpm)) - g.y(Double(bin.rpm + Cloud.rpmBin)))
                let alpha = (0.05 + 0.4 * sqrt(Double(count) / Double(peak))) * weight
                context.fill(Path(rect), with: .color(Palette.apple.opacity(alpha)))
            }
        }
    }
}

/// The animated half of the plot. Its animatable data is every live
/// number; SwiftUI feeds intermediate vectors while a change settles.
struct LiveLayer: View, @MainActor Animatable {
    let frame: Frame
    let geometry: PlotGeometry
    var vec: Vec

    init(frame: Frame, geometry: PlotGeometry) {
        self.frame = frame
        self.geometry = geometry
        vec = LiveLayer.encode(frame)
    }

    var animatableData: Vec {
        get { vec }
        set { vec = newValue }
    }

    /// [die or -1000] + actuals + targets + the curve's (c, rpm) pairs.
    static func encode(_ f: Frame) -> Vec {
        var v = [f.die ?? -1000]
        v += f.actuals
        v += f.targets
        if let curve = f.curve { v += curve.points.flatMap { [$0.c, $0.rpm] } }
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
        let actuals = Array(v[1..<1 + frame.actuals.count])
        let targets = Array(
            v[1 + frame.actuals.count..<1 + frame.actuals.count + frame.targets.count])
        var curve = frame.curve
        if let known = frame.curve {
            let base = 1 + frame.actuals.count + frame.targets.count
            let points = (0..<known.points.count).map {
                Curve.Point(c: v[base + $0 * 2], rpm: v[base + $0 * 2 + 1])
            }
            curve = (try? Curve(name: known.name, points: points)) ?? known
        }

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

        // The curve, in dune, sampled every half degree from the same
        // function the daemon writes; a soft fill under it, the selected
        // point ringed and labelled below the line.
        if let curve {
            var line = Path()
            line.move(to: CGPoint(x: plot.minX, y: g.y(curve.rpm(at: Frame.celsius.lowerBound))))
            for c in stride(
                from: Frame.celsius.lowerBound, through: Frame.celsius.upperBound, by: 0.5)
            {
                line.addLine(to: CGPoint(x: g.x(c), y: g.y(curve.rpm(at: c))))
            }
            var under = line
            under.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY))
            under.addLine(to: CGPoint(x: plot.minX, y: plot.maxY))
            under.closeSubpath()
            context.fill(under, with: .color(Palette.dune.opacity(0.08)))
            context.stroke(
                line, with: .color(Palette.dune.opacity(0.95)),
                style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            for (i, p) in curve.points.enumerated() {
                let r: CGFloat = i == frame.point ? 6 : 4
                let dot = CGRect(x: g.x(p.c) - r, y: g.y(p.rpm) - r, width: r * 2, height: r * 2)
                context.fill(Path(ellipseIn: dot), with: .color(Palette.dune))
                if i == frame.point {
                    context.stroke(
                        Path(ellipseIn: dot.insetBy(dx: -4, dy: -4)),
                        with: .color(Palette.dune.opacity(0.5)), lineWidth: 1.5)
                    context.draw(
                        Text("\(Int(p.c))° · \(Int(p.rpm)) rpm").font(.meta)
                            .foregroundStyle(Palette.dune),
                        at: CGPoint(x: g.x(p.c), y: g.y(p.rpm) + 18))
                }
            }
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
            context.stroke(line, with: .color(heat.opacity(0.7)), lineWidth: 1)
            context.draw(
                Text("die \(Status.degrees(die))").font(.meta).foregroundStyle(heat),
                at: CGPoint(x: g.x(die) + 34, y: plot.minY + 8))
            for (i, actual) in actuals.enumerated() {
                let dot = CGRect(x: g.x(die) - 5, y: g.y(actual) - 5, width: 10, height: 10)
                context.stroke(Path(ellipseIn: dot), with: .color(Palette.dune), lineWidth: 1.5)
                let dy: CGFloat = actuals.count > 1 && i == 0 ? -9 : 9
                context.draw(
                    Text("fan \(i + 1) · \(Int(actual)) rpm").font(.meta)
                        .foregroundStyle(Palette.dune),
                    at: CGPoint(x: g.x(die) + 12, y: g.y(actual) + dy), anchor: .leading)
            }
            for target in targets {
                let dot = CGRect(x: g.x(die) - 4, y: g.y(target) - 4, width: 8, height: 8)
                context.fill(Path(ellipseIn: dot), with: .color(Palette.dune))
            }
        }
    }
}
