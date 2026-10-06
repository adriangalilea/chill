import AppKit
import ChillKit

/// The menu bar glyph's geometry, ONE constant: the blade and the hub of
/// `scripts/glyph.svg` in its 1024 viewBox. The SVG is the drawing and
/// `Glyph` renders these same numbers, so the file and the bar never draw
/// two different fans. The app icon is `chill.icon` (Icon Composer).
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

    /// chill's fan while it holds the fans: its brand sand, the hue the plot
    /// gives what chill does, as the fill. The edge is what keeps it legible
    /// on any wallpaper: on a light bar, where sand alone would fade or turn
    /// brown if darkened, it is the bar's own dark ink; on a dark bar the
    /// bright sand already stands out, so edge and fill are one.
    static let sand = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0xe9 / 255, green: 0xd7 / 255, blue: 0xb0 / 255, alpha: 1)
            : NSColor(srgbRed: 0xd9 / 255, green: 0xc1 / 255, blue: 0x93 / 255, alpha: 1)
    }
    static let sandEdge = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? Glyph.sand
            : NSColor(white: 0, alpha: 0.85)
    }

    /// Who holds the fans, at a glance. chill's curve (filled, bar) is its
    /// own color, sand, stroked heavy. Every other state is the menu bar's
    /// own ink as a template image, which the system tints for whatever bar
    /// it sits on: Apple's idle (outline) thinner and see-through, trouble
    /// (slashed, dotted) at full strength, since it asks for attention.
    var tinted: Bool { self == .filled || self == .bar }

    /// The glyph for a menu bar in `appearance`. A template is the same on
    /// any bar; chill's sand is resolved for that bar here, since a status
    /// item's image is drawn without its button's appearance current.
    func image(on appearance: NSAppearance) -> NSImage {
        var ink = NSColor.black.cgColor
        var edge = NSColor.black.cgColor
        if tinted {
            appearance.performAsCurrentDrawingAppearance {
                ink = Glyph.sand.cgColor
                edge = Glyph.sandEdge.cgColor
            }
        }
        let image = NSImage(size: NSSize(width: Glyph.side, height: Glyph.side), flipped: true) {
            rect in
            let cg = NSGraphicsContext.current!.cgContext
            let scale = rect.width / Mark.box
            cg.scaleBy(x: scale, y: scale)
            // chill's own states: sand blades with a crisp edge, so the fan
            // has its tone and its shape at 18 pt; Apple's idle the least ink.
            let stroke =
                (self.tinted ? 1.6 : self == .outline ? 1.2 : 1.6) / scale
            cg.setAlpha(self.strength)
            cg.setLineWidth(stroke)
            cg.setLineCap(.round)
            cg.setLineJoin(.round)
            cg.setStrokeColor(edge)
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
        if filled { cg.drawPath(using: .fillStroke) } else { cg.strokePath() }
        cg.setAlpha(strength)
    }
}
