import AppKit
import ChillKit

/// The mark's geometry on the app side, ONE constant: the blade and the
/// hub of `scripts/icon.svg` in its 1024 viewBox. The SVG IS the drawing;
/// `mise icon` rasterizes the icns from it and the menu bar glyph is a
/// render of these same numbers (`Glyph`), so the app and the icon can
/// never draw two different fans.
enum Mark {
    static let box: CGFloat = 1024
    static let center = CGPoint(x: 512, y: 512)
    static let hubRadius: CGFloat = 52
    /// The SVG's stroke width, the proportion the glyph keeps.
    static let strokeWidth: CGFloat = 34

    /// `M 512 430 Q 462 300 522 176 Q 606 296 512 430 Z`
    static var blade: CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 512, y: 430))
        path.addQuadCurve(to: CGPoint(x: 522, y: 176), control: CGPoint(x: 462, y: 300))
        path.addQuadCurve(to: CGPoint(x: 512, y: 430), control: CGPoint(x: 606, y: 296))
        path.closeSubpath()
        return path
    }

    /// The three blades: one shape rotated by 120 degrees about the center.
    static var blades: CGPath {
        let path = CGMutablePath()
        for turn in 0..<3 {
            let transform = CGAffineTransform(translationX: center.x, y: center.y)
                .rotated(by: CGFloat(turn) * 2 * .pi / 3)
                .translatedBy(x: -center.x, y: -center.y)
            path.addPath(blade, transform: transform)
        }
        return path
    }

    static var hub: CGPath {
        CGPath(
            ellipseIn: CGRect(
                x: center.x - hubRadius, y: center.y - hubRadius, width: hubRadius * 2,
                height: hubRadius * 2), transform: nil)
    }
}

/// The status item's image: EFFECT, read from the daemon, never intent.
/// outline = Apple holds the fans · filled = a curve does · bar = boost ·
/// slashed = no daemon this process can read (not installed, awaiting
/// approval, unreachable, a bare build that cannot reach one, or a chill
/// older than chilld) · dotted = someone else forced them.
enum Glyph: Equatable {
    case outline, filled, bar, slashed, dotted

    init(_ link: Link?) {
        guard case .live(let state)? = link else {
            self = .slashed
            return
        }
        switch state.holder {
        case .apple, .acquiring: self = .outline
        case .foreign: self = .dotted
        case .chill:
            if case .boost = state.intent { self = .bar } else { self = .filled }
        }
    }

    /// 18 pt square, the menu bar's native size. The stroke is thickened past
    /// the SVG's proportion: 34/1024 of 18 pt is under a point, invisible.
    static let side: CGFloat = 18

    /// chill's ink while it holds the fans: dune, the hue the plot gives
    /// what chill does, toned per menu bar appearance so it reads on a
    /// light bar as on a dark one.
    static let dune = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0xe6 / 255, green: 0xd6 / 255, blue: 0xb8 / 255, alpha: 1)
            : NSColor(srgbRed: 0x6a / 255, green: 0x55 / 255, blue: 0x30 / 255, alpha: 1)
    }

    /// Who holds the fans, at a glance. chill's curve (filled, bar) is its
    /// own color, dune, stroked heavy. Every other state is the menu bar's
    /// own ink as a template image, which the system tints for whatever bar
    /// it sits on: Apple's idle (outline) thinner and see-through, trouble
    /// (slashed, dotted) at full strength, since it asks for attention.
    var tinted: Bool { self == .filled || self == .bar }

    /// The glyph for a menu bar in `appearance`. A template is the same on
    /// any bar; chill's dune is resolved for that bar here, since a status
    /// item's image is drawn without its button's appearance current.
    func image(on appearance: NSAppearance) -> NSImage {
        var ink = NSColor.black.cgColor
        if tinted {
            appearance.performAsCurrentDrawingAppearance { ink = Glyph.dune.cgColor }
        }
        let image = NSImage(size: NSSize(width: Glyph.side, height: Glyph.side), flipped: true) {
            rect in
            let cg = NSGraphicsContext.current!.cgContext
            let scale = rect.width / Mark.box
            cg.scaleBy(x: scale, y: scale)
            // chill's own states carry the most ink: the filled blades
            // stroked heavy, so the fan has mass at 18 pt; Apple's idle the
            // least.
            let stroke =
                (self.tinted ? 2.4 : self == .outline ? 1.2 : 1.6) / scale
            cg.setAlpha(self.strength)
            cg.setLineWidth(stroke)
            cg.setLineCap(.round)
            cg.setLineJoin(.round)
            cg.setStrokeColor(ink)
            cg.setFillColor(ink)
            switch self {
            case .outline:
                cg.addPath(Mark.blades)
                cg.strokePath()
                self.hub(cg, filled: false)
            case .filled:
                // Filled and stroked: the blades at their full mass.
                cg.addPath(Mark.blades)
                cg.drawPath(using: .fillStroke)
                self.hub(cg, filled: true)
            case .bar:
                cg.addPath(Mark.blades)
                cg.drawPath(using: .fillStroke)
                self.hub(cg, filled: true)
                cg.fill(CGRect(x: 96, y: 930, width: Mark.box - 192, height: 70))
            case .slashed:
                cg.addPath(Mark.blades)
                cg.strokePath()
                self.hub(cg, filled: false)
                cg.setLineWidth(stroke * 1.25)
                cg.move(to: CGPoint(x: 140, y: 884))
                cg.addLine(to: CGPoint(x: 884, y: 140))
                cg.strokePath()
            case .dotted:
                cg.setLineDash(phase: 0, lengths: [stroke * 1.4, stroke * 1.8])
                cg.addPath(Mark.blades)
                cg.strokePath()
                self.hub(cg, filled: false)
            }
            return true
        }
        image.isTemplate = !tinted
        return image
    }

    /// How strongly the glyph is drawn: Apple's idle half, the rest whole.
    private var strength: CGFloat { self == .outline ? 0.5 : 1 }

    /// The hub at the SVG's .55 of the glyph's strength, a fill or a stroke
    /// like the blades.
    private func hub(_ cg: CGContext, filled: Bool) {
        cg.setAlpha(strength * 0.55)
        cg.addPath(Mark.hub)
        if filled { cg.fillPath() } else { cg.strokePath() }
        cg.setAlpha(strength)
    }
}
