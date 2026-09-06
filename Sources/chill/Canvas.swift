import AppKit
import ChillKit
import Ink
import SwiftUI

/// The one window: the curve list the cursor walks (Ink's
/// CursorScrollView keeps it in view) beside the plot, the status line
/// across the top. Opened from the menu, `c`, a Finder reopen, or the
/// demo's launch; closing it returns the app to the menu bar.
@MainActor
final class CanvasWindow {
    let window: NSWindow

    init(model: Model) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "chill"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 720, height: 420)
        window.contentView = NSHostingView(rootView: CanvasView(model: model))
        window.center()
    }

    func open() {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func close() { window.close() }
}

extension Font {
    /// Mono for metadata only: kickers, the status line, axis labels.
    static let meta = Font.system(size: 11, weight: .medium, design: .monospaced)
}

/// The mark's ink, the one hue every colored thing on the canvas wears;
/// alpha is the only variable.
let tone = Color(red: 0xDF / 255.0, green: 0xF3 / 255.0, blue: 0xFF / 255.0)

struct CanvasView: View {
    let model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: .inkBlock) {
            HStack(alignment: .firstTextBaseline, spacing: .inkLane) {
                Text(model.editing?.name ?? "system")
                    .font(.system(size: 20, weight: .semibold))
                if model.demo.on {
                    Text("demo").font(.meta).foregroundStyle(.tertiary)
                }
                Spacer()
                Text(model.statusLine)
                    .font(.meta)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let aside = model.aside {
                Text(aside)
                    .font(.meta)
                    .foregroundStyle(tone.opacity(0.8))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            HStack(alignment: .top, spacing: .inkBlock) {
                CurveList(model: model)
                    .frame(width: 200)
                Plot(model: model)
            }
            Text(hint)
                .font(.meta)
                .foregroundStyle(.tertiary)
        }
        .padding(20)
        .padding(.top, 8)
    }

    /// The affordances this surface has, in its own keys.
    private var hint: String {
        let s = model.store
        func k(_ a: ChillAction) -> String { s.displayPrimary(for: a) }
        return
            "\(k(.pointUp))\(k(.pointDown)) rpm · \(k(.pointLeft))\(k(.pointRight)) °C · \(k(.nextPoint)) next point · \(k(.addPoint)) add · \(k(.removePoint)) remove · \(k(.previousCurve))\(k(.nextCurve)) curves · \(k(.useCurve)) use · \(k(.help)) all keys"
    }
}

/// The curves on disk, the cursor row raised, the daemon's one marked.
struct CurveList: View {
    let model: Model

    var body: some View {
        CursorScrollView(cursor: model.cursor) {
            VStack(spacing: 2) {
                ForEach(model.curves, id: \.name) { curve in
                    row(curve).id(curve.name)
                }
                if model.curves.isEmpty {
                    Text("no curves: \(model.store.displayPrimary(for: .newCurve)) draws one")
                        .font(.meta)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.inkGap)
                }
            }
        }
    }

    private func row(_ curve: Curve) -> some View {
        let selected = model.cursor == curve.name
        return HStack(spacing: .inkGap) {
            VStack(alignment: .leading, spacing: 2) {
                Text(curve.name)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                Text(Status.points(curve))
                    .font(.meta)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if model.intentCurve == curve.name {
                Text("active").font(.meta).foregroundStyle(tone.opacity(0.7))
            }
        }
        .padding(.horizontal, .inkLane)
        .padding(.vertical, .inkGap)
        .background(
            selected ? Color.inkSelection : .clear,
            in: RoundedRectangle(cornerRadius: .inkRow)
        )
        .overlay(
            RoundedRectangle(cornerRadius: .inkRow)
                .strokeBorder(selected ? Color.inkEdge : .clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            model.cursor = curve.name
            model.use(curve)
        }
        .onTapGesture {
            model.cursor = curve.name
            model.point = 0
        }
    }
}

/// What one frame of the plot draws, snapshotted from the model so the
/// renderer closure reads values, not observables.
private struct Frame {
    /// nil while nothing reported one: the y-axis is not drawn.
    let envelope: ClosedRange<Double>?
    let clouds: [Int: [Bin: Int]]
    let curve: Curve?
    let point: Int
    let die: Double?
    let actuals: [Double]
    let targets: [Double]

    static let celsius: ClosedRange<Double> = 30...110
}

/// The reference clouds, the curve under edit with its selected point,
/// and the live markers: the hottest die as a hairline, each fan's
/// actual (open) and target (filled) on it. y spans the fans' envelope.
struct Plot: View {
    let model: Model

    var body: some View {
        let frame = Frame(
            envelope: model.envelope, clouds: model.clouds.bins, curve: model.editing,
            point: model.point, die: model.die, actuals: model.actuals, targets: model.targets)
        Canvas { context, size in
            draw(frame, in: context, size: size)
        }
        .background(
            RoundedRectangle(cornerRadius: .inkField).fill(Color.inkRest.opacity(0.4)))
    }

    private static let inset = EdgeInsets(top: 12, leading: 48, bottom: 28, trailing: 12)

    private func draw(_ f: Frame, in context: GraphicsContext, size: CGSize) {
        let plot = CGRect(
            x: Plot.inset.leading, y: Plot.inset.top,
            width: size.width - Plot.inset.leading - Plot.inset.trailing,
            height: size.height - Plot.inset.top - Plot.inset.bottom)
        guard plot.width > 0, plot.height > 0, let envelope = f.envelope else { return }
        let ySpan = envelope.upperBound - envelope.lowerBound
        let yLo = envelope.lowerBound - ySpan * 0.05
        let yHi = envelope.upperBound + ySpan * 0.05
        func x(_ c: Double) -> CGFloat {
            plot.minX + plot.width * (c - Frame.celsius.lowerBound)
                / (Frame.celsius.upperBound - Frame.celsius.lowerBound)
        }
        func y(_ rpm: Double) -> CGFloat {
            plot.maxY - plot.height * (rpm - yLo) / (yHi - yLo)
        }

        // The grid: hairlines every 10 °C and 1000 rpm, mono labels.
        let hair = GraphicsContext.Shading.color(.primary.opacity(0.07))
        for c in stride(from: Frame.celsius.lowerBound, through: Frame.celsius.upperBound, by: 10) {
            var line = Path()
            line.move(to: CGPoint(x: x(c), y: plot.minY))
            line.addLine(to: CGPoint(x: x(c), y: plot.maxY))
            context.stroke(line, with: hair, lineWidth: 1)
            context.draw(
                Text("\(Int(c))°").font(.meta).foregroundStyle(.tertiary),
                at: CGPoint(x: x(c), y: plot.maxY + 14))
        }
        for rpm in stride(from: (yLo / 1000).rounded(.up) * 1000, through: yHi, by: 1000) {
            var line = Path()
            line.move(to: CGPoint(x: plot.minX, y: y(rpm)))
            line.addLine(to: CGPoint(x: plot.maxX, y: y(rpm)))
            context.stroke(line, with: hair, lineWidth: 1)
            context.draw(
                Text("\(Int(rpm))").font(.meta).foregroundStyle(.tertiary),
                at: CGPoint(x: plot.minX - 24, y: y(rpm)))
        }

        // The clouds: alpha by density, the second fan half as strong.
        for fan in f.clouds.keys.sorted() {
            let table = f.clouds[fan]!
            guard let peak = table.values.max(), peak > 0 else { continue }
            let weight = fan == 0 ? 1.0 : 0.5
            for (bin, count) in table {
                let rect = CGRect(
                    x: x(Double(bin.c)), y: y(Double(bin.rpm + Cloud.rpmBin)),
                    width: x(Double(bin.c) + 1) - x(Double(bin.c)),
                    height: y(Double(bin.rpm)) - y(Double(bin.rpm + Cloud.rpmBin)))
                let alpha = (0.08 + 0.6 * sqrt(Double(count) / Double(peak))) * weight
                context.fill(Path(rect), with: .color(tone.opacity(alpha)))
            }
        }

        // The curve: flat beyond its ends, the selected point ringed.
        if let curve = f.curve {
            var line = Path()
            line.move(to: CGPoint(x: plot.minX, y: y(curve.points.first!.rpm)))
            for p in curve.points { line.addLine(to: CGPoint(x: x(p.c), y: y(p.rpm))) }
            line.addLine(to: CGPoint(x: plot.maxX, y: y(curve.points.last!.rpm)))
            context.stroke(
                line, with: .color(.primary.opacity(0.9)),
                style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            for (i, p) in curve.points.enumerated() {
                let r: CGFloat = i == f.point ? 6 : 4
                let dot = CGRect(x: x(p.c) - r, y: y(p.rpm) - r, width: r * 2, height: r * 2)
                context.fill(Path(ellipseIn: dot), with: .color(.primary))
                if i == f.point {
                    context.stroke(
                        Path(ellipseIn: dot.insetBy(dx: -4, dy: -4)),
                        with: .color(.primary.opacity(0.5)), lineWidth: 1.5)
                    context.draw(
                        Text("\(Int(p.c))° · \(Int(p.rpm)) rpm").font(.meta)
                            .foregroundStyle(.secondary),
                        at: CGPoint(x: x(p.c), y: y(p.rpm) - 18))
                }
            }
        }

        // Live: the hottest die, each fan's actual and target on it.
        if let die = f.die {
            var line = Path()
            line.move(to: CGPoint(x: x(die), y: plot.minY))
            line.addLine(to: CGPoint(x: x(die), y: plot.maxY))
            context.stroke(line, with: .color(tone.opacity(0.7)), lineWidth: 1)
            context.draw(
                Text(Status.degrees(die)).font(.meta).foregroundStyle(tone),
                at: CGPoint(x: x(die) + 18, y: plot.minY + 8))
            for actual in f.actuals {
                let dot = CGRect(x: x(die) - 5, y: y(actual) - 5, width: 10, height: 10)
                context.stroke(Path(ellipseIn: dot), with: .color(tone), lineWidth: 1.5)
            }
            for target in f.targets {
                let dot = CGRect(x: x(die) - 4, y: y(target) - 4, width: 8, height: 8)
                context.fill(Path(ellipseIn: dot), with: .color(tone))
            }
        }
    }
}
