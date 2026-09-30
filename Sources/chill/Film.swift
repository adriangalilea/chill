import AppKit
import ChillKit
import SwiftUI

/// Where the film's pointer can go, published by the popover's own
/// controls as anchors: the pointer lands on the real tab and the real
/// knob, resolved in the same render pass, whatever the layout does.
enum FilmMark: Hashable {
    case tab(Model.Tab)
    case knob
}

struct FilmMarks: PreferenceKey {
    static var defaultValue: [FilmMark: Anchor<CGRect>] { [:] }
    static func reduce(
        value: inout [FilmMark: Anchor<CGRect>], nextValue: () -> [FilmMark: Anchor<CGRect>]
    ) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    /// Publishes this view's bounds as a film mark.
    func filmMark(_ mark: FilmMark) -> some View {
        anchorPreference(key: FilmMarks.self, value: .bounds) { [mark: $0] }
    }
}

/// The popover telling one of chill's stories, drawn by the app's own views
/// on a virtual clock. Every frame is a fresh `ImageRenderer` pass at
/// `scale`, so a clip is as sharp as the page wants whatever the display
/// is; nothing animates on the wall clock, every motion is a value the
/// story gives the frame (the heat, the tab, the knob, who is watching,
/// the pointer) or the fans stepped by the demo daemon's physics. At a cut
/// (a tab pressed, the watcher gone or back) the frame before crossfades
/// into the frame after. Two cuts of the same story:
/// - a film (`chill --demo film`): the popover on a desk under its menu bar
///   glyph, with the pointer, a picture on its own;
/// - a surface (`chill --demo scene`): the popover alone at its own size,
///   the clip `@ag/macos` hangs from the glyph on its stage.
@MainActor
enum Film {
    static let fps = 30.0
    /// The film's stage in points; the popover is 460 wide on it.
    static let stage = CGSize(width: 640, height: 400)
    static let scale: CGFloat = 3
    static let fade = 0.3

    enum Place {
        case at(CGPoint)
        case mark(FilmMark)
        /// On the knob's handle, wherever the knob is at that instant.
        case handle
    }

    /// Where the pointer waits between acts, and where it enters and leaves.
    static let rest = CGPoint(x: 600, y: 380)
    static let offstage = CGPoint(x: 700, y: 440)

    /// What the app sees at an instant: the tab the daemon runs and whether
    /// this Mac has someone at it.
    struct UI: Equatable {
        let tab: Model.Tab
        let watching: Bool
    }

    struct Story {
        let length: Double
        let die: (Double) -> Double
        let push: (Double) -> Double
        let ui: (Double) -> UI
        /// The instants `ui` changes.
        let cuts: [Double]
        /// Keyframes of (time, place, pressed); between two the pointer
        /// eases from one place to the next.
        let path: [(t: Double, place: Place, pressed: Bool)]

        func pointer(at t: Double) -> (from: Place, to: Place, u: Double, pressed: Bool) {
            let next = path.firstIndex { $0.t > t } ?? path.count - 1
            let a = path[max(0, next - 1)]
            let b = path[next]
            let u = b.t > a.t ? min(1, max(0, (t - a.t) / (b.t - a.t))) : 1
            return (a.place, b.place, ease(u), a.pressed)
        }
    }

    static let stories: [String: Story] = ["hero": hero, "walk-away": walkAway]

    /// The value in one breath: press chill, push the knob as the heat
    /// arrives, the fans ride the curve up and down, press apple and
    /// Apple's curve takes them back.
    static let hero = Story(
        length: 20,
        die: { t in
            let idle = 47 + 0.4 * sin(t * 1.3)
            let peak = 72 + 0.6 * sin(t * 1.7)
            let cool = 53 + 0.4 * sin(t * 1.1)
            if t < 4.5 { return idle }
            if t < 9.5 { return mix(idle, peak, ease((t - 4.5) / 5)) }
            if t < 11.5 { return peak }
            if t < 16 { return mix(peak, cool, ease((t - 11.5) / 4.5)) }
            return cool
        },
        push: { t in mix(0.30, 0.45, ease((t - 3.0) / 2.2)) },
        ui: { t in UI(tab: t < 1.6 || t >= 16.8 ? .apple : .tuned, watching: true) },
        cuts: [1.6, 16.8],
        path: [
            (0.0, .at(rest), false),
            (1.3, .mark(.tab(.tuned)), false),
            (1.45, .mark(.tab(.tuned)), true),
            (1.65, .mark(.tab(.tuned)), false),
            (2.0, .mark(.tab(.tuned)), false),
            (2.7, .handle, false),
            (2.9, .handle, true),
            (5.3, .handle, true),
            (5.45, .handle, false),
            (6.6, .at(rest), false),
            (15.4, .at(rest), false),
            (16.5, .mark(.tab(.apple)), false),
            (16.65, .mark(.tab(.apple)), true),
            (16.85, .mark(.tab(.apple)), false),
            (17.6, .mark(.tab(.apple)), false),
            (19.2, .at(rest), false),
        ])

    /// The contract, as the clip the stage's walk-away scene opens twice:
    /// chill holding the fans while someone watches (`holding`), nobody
    /// watching from `gone` (the lock screen is the stage's), and the
    /// watcher back at `back`, where the scene reopens the popover a beat
    /// before, on the fans at Apple's curve with the drop in the afterglow.
    static let holding = 0.0
    static let gone = 10.0
    static let back = 15.0
    static let walkAway = Story(
        length: 22,
        die: { t in 68 + 0.5 * sin(t * 1.4) },
        push: { _ in 0.45 },
        ui: { t in UI(tab: .tuned, watching: t < gone || t >= back) },
        cuts: [gone, back],
        path: [(0, .at(offstage), false)])

    // MARK: - the world

    /// The demo daemon's fans and its verdicts, stepped on the film's clock
    /// with the same physics (`FakeDaemon.target`, `slew`, `holder`,
    /// `reason`), so the film shows what the demo world does.
    @MainActor struct World {
        var actual = FakeDaemon.fans.map(\.min)

        static func intent(_ tab: Model.Tab, push: Double) -> Intent {
            switch tab {
            case .tuned:
                let envelope = FakeDaemon.fans.map(\.min).min()!...FakeDaemon.fans.map(\.max).max()!
                return .curve(Model.tuned(push: push, envelope: envelope))
            case .apple: return .system
            case .gust, .custom:
                preconditionFailure("the film's stories press apple and chill only")
            }
        }

        mutating func step(die: Double, intent: Intent, watching: Bool, seconds: Double) {
            for fan in FakeDaemon.fans {
                let target = FakeDaemon.target(
                    fan, die: die, intent: intent, forced: intent != .system && watching)
                actual[fan.index] = FakeDaemon.slew(
                    actual[fan.index], toward: target, seconds: seconds)
            }
        }

        /// What the daemon would reply: `intent` persisted, forced only while
        /// someone watches.
        func state(die: Double, intent: Intent, watching: Bool, name: String = Role.app.rawValue)
            -> ChillKit.State
        {
            let forced = intent != .system && watching
            return ChillKit.State(
                intent: intent, holder: FakeDaemon.holder(intent, forced: forced), vetoes: [],
                presence: watching ? Presence(pid: getpid(), name: name, secondsLeft: 10) : nil,
                fans: FakeDaemon.fans.map { fan in
                    FanState(
                        index: fan.index, actual: actual[fan.index].rounded(),
                        target: FakeDaemon.target(fan, die: die, intent: intent, forced: forced)
                            .rounded(),
                        mode: forced ? 1 : 3)
                },
                die: die, dieSensors: FakeDaemon.dieSensors, dieSource: "cpu",
                lastReason: FakeDaemon.reason(intent, forced: forced).description, clouds: [])
        }
    }

    // MARK: - the render

    /// The demo model the frames draw, in the dark appearance the page wears.
    static func model() -> Model {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        app.appearance = NSAppearance(named: .darkAqua)
        let model: Model
        do { model = try Model(demo: Demo(on: true)) } catch { Verbs.die("film: \(error)") }
        model.hello = Hello(
            daemonVersion: Wire.version, protocolVersion: Wire.protocolVersion, pid: getpid(),
            fans: FakeDaemon.fans)
        model.popoverShown = true
        return model
    }

    static func story(_ name: String) -> Story {
        guard let story = stories[name] else {
            Verbs.die(
                "film: no story '\(name)'; stories: \(stories.keys.sorted().joined(separator: ", "))"
            )
        }
        return story
    }

    /// Renders `story` into `out` (H.264) and returns the frame's size in
    /// points: the film's stage, or the popover's own for a surface.
    @discardableResult
    static func render(_ story: Story, surface: Bool, model: Model, out: URL) -> CGSize {
        // A story opens in its steady state: the fans already where its
        // first instant puts them.
        var world = World()
        for _ in 0..<Int(10 * fps) {
            let ui = story.ui(0)
            world.step(
                die: story.die(0), intent: World.intent(ui.tab, push: story.push(0)),
                watching: ui.watching, seconds: 1 / fps)
        }
        var encoder: Encoder?
        var size = CGSize.zero
        let frames = Int(story.length * fps)
        let start = Date(timeIntervalSinceReferenceDate: 0)
        for i in 0..<frames {
            let t = Double(i) / fps
            let die = story.die(t)
            let push = story.push(t)
            let ui = story.ui(t)
            world.step(
                die: die, intent: World.intent(ui.tab, push: push), watching: ui.watching,
                seconds: 1 / fps)
            model.config.push = push
            model.filmTime = start.addingTimeInterval(t)

            let frame = { (ui: UI) -> CGImage in
                model.watching = ui.watching
                model.link = .live(
                    world.state(
                        die: die, intent: World.intent(ui.tab, push: push),
                        watching: ui.watching))
                return draw(model, story: story, surface: surface, t: t)
            }
            let now = frame(ui)
            // The first frame fixes the size; a surface that changes size
            // mid-story is a popover that resized, the bug the foot exists
            // to prevent.
            if encoder == nil {
                size = CGSize(
                    width: CGFloat(now.width) / scale, height: CGFloat(now.height) / scale)
                encoder = Encoder(out: out, width: now.width, height: now.height, fps: fps)
            }
            precondition(
                CGFloat(now.width) == size.width * scale
                    && CGFloat(now.height) == size.height * scale,
                "film: the frame at \(t)s is \(now.width)×\(now.height), not \(size) at \(scale)x")
            if let cut = story.cuts.last(where: { $0 <= t }), t - cut < fade {
                let before = story.ui(cut - 1 / fps)
                precondition(before != ui, "film: the cut at \(cut)s changes nothing")
                encoder!.write(frame(before), over: now, alpha: ease((t - cut) / fade))
            } else {
                encoder!.write(now)
            }
        }
        encoder!.finish()
        return size
    }

    /// `chill --demo film <story> <out.mp4>`: the film cut, then exit.
    static func run(story name: String, out: URL) -> Never {
        let model = model()
        render(story(name), surface: false, model: model, out: out)
        print("film: \(out.path) (\(name))")
        exit(0)
    }

    private static func draw(_ model: Model, story: Story, surface: Bool, t: Double) -> CGImage {
        let renderer: ImageRenderer<AnyView>
        if surface {
            renderer = ImageRenderer(content: AnyView(SurfaceFrame(model: model)))
        } else {
            renderer = ImageRenderer(content: AnyView(FilmFrame(model: model, story: story, t: t)))
            renderer.proposedSize = ProposedViewSize(stage)
        }
        renderer.scale = scale
        renderer.isOpaque = true
        guard let image = renderer.cgImage else { Verbs.die("film: frame at \(t)s did not render") }
        return image
    }

    /// The color the popover is drawn on, as `#rrggbb` in sRGB: the dark
    /// window background, which the stage's arrow and border wear too.
    static var background: String {
        var hex = ""
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
            let c = NSColor.windowBackgroundColor.usingColorSpace(.sRGB)!
            hex = String(
                format: "#%02x%02x%02x", Int((c.redComponent * 255).rounded()),
                Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
        }
        return hex
    }

    nonisolated static func mix(_ a: Double, _ b: Double, _ u: Double) -> Double { a + (b - a) * u }
    nonisolated static func ease(_ u: Double) -> Double {
        let u = min(1, max(0, u))
        return u * u * (3 - 2 * u)
    }
}

/// Raw frames into ffmpeg's stdin, out as an H.264 master: BGRA in,
/// Rec. 709 tagged, quality high enough that `pnpm media` re-encodes from
/// something clean.
private final class Encoder {
    private let process = Process()
    private let pipe = Pipe()
    private let context: CGContext
    private let width: Int
    private let height: Int

    init(out: URL, width: Int, height: Int, fps: Double) {
        self.width = width
        self.height = height
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue)
        else { Verbs.die("film: no bitmap context") }
        self.context = context
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "ffmpeg", "-loglevel", "error", "-y",
            "-f", "rawvideo", "-pix_fmt", "bgra", "-s", "\(width)x\(height)", "-r", "\(Int(fps))",
            "-i", "-",
            // H.264 in 4:2:0 wants even dimensions.
            "-vf", "crop=trunc(iw/2)*2:trunc(ih/2)*2,scale=out_color_matrix=bt709:out_range=tv",
            "-c:v", "libx264", "-preset", "slow", "-crf", "12", "-pix_fmt", "yuv420p",
            "-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709",
            "-movflags", "+faststart", out.path,
        ]
        process.standardInput = pipe
        do { try process.run() } catch { Verbs.die("film: ffmpeg: \(error)") }
    }

    func write(_ image: CGImage) {
        write(image, over: nil, alpha: 1)
    }

    /// `over` drawn at `alpha` on top of `image`: the crossfade.
    func write(_ image: CGImage, over: CGImage?, alpha: Double) {
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.setAlpha(1)
        context.draw(image, in: rect)
        if let over {
            context.setAlpha(alpha)
            context.draw(over, in: rect)
        }
        let bytes = Data(bytes: context.data!, count: width * height * 4)
        pipe.fileHandleForWriting.write(bytes)
    }

    func finish() {
        pipe.fileHandleForWriting.closeFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            Verbs.die("film: ffmpeg exited \(process.terminationStatus)")
        }
    }
}

/// The popover alone, as the stage hangs it: its content on the window
/// background, the size SwiftUI lays it out at.
struct SurfaceFrame: View {
    let model: Model

    var body: some View {
        PopoverView(model: model)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .dark)
            .environment(\.locale, .figures)
    }
}

/// One frame of a film: a dark desk, the menu bar with chill's glyph and a
/// clock, the popover hanging from the glyph, and the pointer.
struct FilmFrame: View {
    let model: Model
    let story: Film.Story
    let t: Double

    /// Where the glyph sits on the stage, and so the popover's arrow.
    static let glyphX: CGFloat = 470
    static let barHeight: CGFloat = 24
    static let popoverX: CGFloat = 96

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(white: 0.055)
            RadialGradient(
                colors: [Palette.dune.opacity(0.07), .clear], center: .init(x: 0.73, y: 0),
                startRadius: 0, endRadius: 420)
            menuBar
            popover
                .offset(x: FilmFrame.popoverX, y: FilmFrame.barHeight + 4)
        }
        .frame(width: Film.stage.width, height: Film.stage.height, alignment: .topLeading)
        .overlayPreferenceValue(FilmMarks.self) { marks in
            GeometryReader { proxy in pointer(marks, proxy) }
        }
        .environment(\.colorScheme, .dark)
        .environment(\.locale, .figures)
    }

    /// The glyph at `glyphX`, highlighted as a menu bar item is while its
    /// popover is open, and a clock to its right.
    private var menuBar: some View {
        let mid = FilmFrame.barHeight / 2
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(.white.opacity(0.045))
            Rectangle().fill(.white.opacity(0.06)).frame(height: 1)
                .offset(y: FilmFrame.barHeight - 1)
            RoundedRectangle(cornerRadius: 5).fill(.white.opacity(0.14))
                .frame(width: 30, height: 20)
                .position(x: FilmFrame.glyphX, y: mid)
            Image(nsImage: Glyph(model.link).image())
                .renderingMode(.template)
                .foregroundStyle(.white.opacity(0.92))
                .position(x: FilmFrame.glyphX, y: mid)
            Text("Tue 30 Sep  9:41")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .fixedSize()
                .position(x: FilmFrame.glyphX + 88, y: mid)
        }
        .frame(width: Film.stage.width, height: FilmFrame.barHeight)
    }

    private var popover: some View {
        PopoverView(model: model)
            .background(
                Balloon(arrowX: FilmFrame.glyphX - FilmFrame.popoverX)
                    .fill(Color(nsColor: .windowBackgroundColor))
            )
            .overlay(
                Balloon(arrowX: FilmFrame.glyphX - FilmFrame.popoverX)
                    .stroke(.white.opacity(0.1), lineWidth: 1)
            )
            .compositingGroup()
            .shadow(color: .black.opacity(0.5), radius: 24, y: 10)
    }

    @ViewBuilder
    private func pointer(_ marks: [FilmMark: Anchor<CGRect>], _ proxy: GeometryProxy) -> some View {
        let (from, to, u, pressed) = story.pointer(at: t)
        let a = place(from, marks, proxy)
        let b = place(to, marks, proxy)
        let at = CGPoint(x: a.x + (b.x - a.x) * u, y: a.y + (b.y - a.y) * u)
        let arrow = NSCursor.arrow
        Image(nsImage: arrow.image)
            .scaleEffect(pressed ? 0.88 : 1, anchor: .topLeading)
            .position(
                x: at.x - arrow.hotSpot.x + arrow.image.size.width / 2,
                y: at.y - arrow.hotSpot.y + arrow.image.size.height / 2)
    }

    private func place(
        _ place: Film.Place, _ marks: [FilmMark: Anchor<CGRect>], _ proxy: GeometryProxy
    )
        -> CGPoint
    {
        switch place {
        case .at(let point):
            return point
        case .mark(let mark):
            guard let anchor = marks[mark] else { Verbs.die("film: no \(mark) on screen") }
            let rect = proxy[anchor]
            return CGPoint(x: rect.midX, y: rect.midY)
        case .handle:
            guard let anchor = marks[.knob] else { Verbs.die("film: no knob on screen") }
            let rect = proxy[anchor]
            return CGPoint(x: rect.minX + rect.width * model.config.push, y: rect.midY)
        }
    }
}

/// The popover's outline: a rounded body with the arrow on top at
/// `arrowX`, one path so the border runs around both.
struct Balloon: Shape {
    let arrowX: CGFloat
    static let arrow = CGSize(width: 22, height: 10)
    static let radius: CGFloat = 16

    func path(in rect: CGRect) -> Path {
        let r = Balloon.radius
        let a = Balloon.arrow
        var p = Path()
        p.move(to: CGPoint(x: rect.minX + r, y: rect.minY))
        p.addLine(to: CGPoint(x: arrowX - a.width / 2, y: rect.minY))
        p.addQuadCurve(
            to: CGPoint(x: arrowX, y: rect.minY - a.height),
            control: CGPoint(x: arrowX - a.width / 4, y: rect.minY))
        p.addQuadCurve(
            to: CGPoint(x: arrowX + a.width / 2, y: rect.minY),
            control: CGPoint(x: arrowX + a.width / 4, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        p.addArc(
            center: CGPoint(x: rect.maxX - r, y: rect.minY + r), radius: r,
            startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        p.addArc(
            center: CGPoint(x: rect.maxX - r, y: rect.maxY - r), radius: r,
            startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        p.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        p.addArc(
            center: CGPoint(x: rect.minX + r, y: rect.maxY - r), radius: r,
            startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        p.addArc(
            center: CGPoint(x: rect.minX + r, y: rect.minY + r), radius: r,
            startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        p.closeSubpath()
        return p
    }
}
