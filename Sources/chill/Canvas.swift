import AppKit
import ChillKit
import Ink
import SwiftUI

/// The one window: the curve list the cursor walks (Ink's
/// CursorScrollView keeps it in view) beside the plot, the status line
/// across the top. Opened from the menu, `c`, a Finder reopen, or the
/// demo's launch; closing it returns the app to the menu bar.
@MainActor
final class CanvasWindow: NSObject, NSWindowDelegate {
    let window: NSWindow
    private let model: Model

    init(model: Model) {
        self.model = model
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        super.init()
        window.title = "chill"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 720, height: 420)
        window.contentView = NSHostingView(rootView: CanvasView(model: model))
        window.delegate = self
        window.center()
    }

    func open() {
        NSApp.activate()
        model.labShown = true
        window.makeKeyAndOrderFront(nil)
    }

    func close() { window.close() }

    /// The plot lives only while the window is up: the red button and
    /// `close()` both land here.
    func windowWillClose(_ notification: Notification) { model.labShown = false }
}

extension Font {
    /// Mono for metadata only: kickers, the status line, axis labels.
    static let meta = Font.system(size: 11, weight: .medium, design: .monospaced)
}

/// tempo's ladder, one hue per meaning, alpha the only other variable:
/// dune (its minutes) for what chill does, the curve, the fans, the
/// accent; heat for the die, ice when cool through ember to the alarm
/// red; a plain neutral for what Apple does, the cloud.
enum Palette {
    static let duneHex = "#cfc5b4"
    static let dune = Color(red: 0xCF / 255.0, green: 0xC5 / 255.0, blue: 0xB4 / 255.0)
    static let ice = Color(red: 0xA9 / 255.0, green: 0xC8 / 255.0, blue: 0xEC / 255.0)
    static let ember = Color(red: 0xFF / 255.0, green: 0x74 / 255.0, blue: 0x20 / 255.0)
    static let hot = Color(red: 0xFF / 255.0, green: 0x4F / 255.0, blue: 0x12 / 255.0)
    static let apple = Color.primary

    /// The die's color IS its temperature: ice at 45 °C and below, ember
    /// by 75 °C, red at 100 °C, blended in between.
    static func heat(_ celsius: Double) -> Color {
        func mix(_ a: Color, _ b: Color, _ t: Double) -> Color {
            let (ra, ga, ba) = a.rgb
            let (rb, gb, bb) = b.rgb
            return Color(
                red: ra + (rb - ra) * t, green: ga + (gb - ga) * t, blue: ba + (bb - ba) * t)
        }
        switch celsius {
        case ..<45: return ice
        case ..<75: return mix(ice, ember, (celsius - 45) / 30)
        case ..<100: return mix(ember, hot, (celsius - 75) / 25)
        default: return hot
        }
    }

    /// The same ramp laid across the plot, the heatmap the die reveals.
    static let heatGradient = Gradient(stops: [
        .init(color: ice, location: 0),
        .init(color: ice, location: PlotGeometry.unit(45)),
        .init(color: ember, location: PlotGeometry.unit(75)),
        .init(color: hot, location: PlotGeometry.unit(100)),
        .init(color: hot, location: 1),
    ])
}

extension Color {
    /// The sRGB components, for blending two palette colors.
    fileprivate var rgb: (Double, Double, Double) {
        let c = NSColor(self).usingColorSpace(.sRGB)!
        return (c.redComponent, c.greenComponent, c.blueComponent)
    }
}

let tone = Palette.dune

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
                ZStack {
                    if model.labShown {
                        Plot(model: model, curve: model.editing, editable: true)
                    }
                }
            }
            ActionBar(model: model)
            Text(hint)
                .font(.meta)
                .foregroundStyle(.tertiary)
        }
        .padding(20)
        .padding(.top, 8)
    }

    /// The affordances this surface has, the pointer's.
    private var hint: String {
        "press the line: a new point, drag it · right-click: remove it · double-click: use the curve"
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
