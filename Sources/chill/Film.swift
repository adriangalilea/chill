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
/// on a virtual clock: the surface clip `@ag/macos` hangs from chill's glyph
/// on its stage (`chill --demo scene`). Every frame is a fresh
/// `ImageRenderer` pass at `scale`, so a clip is as sharp as the page wants
/// whatever the display is; nothing animates on the wall clock, every
/// motion is a value the story gives the frame (the heat, the tab, the
/// knob, who is watching, the pointer) or the fans stepped by the demo
/// daemon's physics. At a cut (a tab pressed, the watcher gone or back) the
/// frame before crossfades into the frame after.
@MainActor
enum Film {
    static let fps = 30.0
    static let scale: CGFloat = 3
    static let fade = 0.3

    enum Place {
        case at(CGPoint)
        case mark(FilmMark)
        /// On the knob's handle, wherever the knob is at that instant.
        case handle
    }

    /// Where the pointer waits between acts, in the popover's points: past
    /// its bottom-right corner, on the desktop the stage draws around it, so
    /// the clip shows it arriving from outside and leaving again.
    static let outside = CGPoint(x: 540, y: 380)

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

    /// The value in one breath, a hot Mac: a long load arrives on Apple's
    /// curve, which keeps the fans off while the chip climbs and then holds
    /// them at their floor; the pointer presses chill and pushes the knob,
    /// the fans ride the curve up and the chip comes down under the same
    /// load. The die is the heat model's chip (`heroHeat`), so the plot and
    /// the stage's thermal view (`Scene.hero`) are one simulation.
    nonisolated static let heroChill = 3.5
    /// The last reading, as the stage ends: past it the stage would hold.
    nonisolated static let heroLength = 10.0
    /// When the pointer takes the knob: once the stage has gone inside
    /// (Scene.hero), so the push and the fans answering it are seen together
    /// and nothing moves on the popover while the view changes.
    nonisolated static let heroPushAt = 5.2
    /// The clip runs past the story's last beat, so the stage, which holds
    /// the last caption until it is read, never outruns the popover.
    nonisolated static let heroClip = heroLength + 5
    nonisolated static func heroUI(_ t: Double) -> UI {
        UI(tab: t < heroChill ? .apple : .tuned, watching: true)
    }
    nonisolated static func heroPush(_ t: Double) -> Double {
        mix(0.35, 0.75, ease((t - heroPushAt) / 0.8))
    }
    static let hero = Story(
        length: heroClip,
        die: { t in heroHeat[min(heroHeat.count - 1, Int((t * fps).rounded()))].heat.cpu },
        push: heroPush,
        ui: heroUI,
        cuts: [heroChill],
        path: [
            (0.0, .at(outside), false),
            (heroChill - 0.6, .at(outside), false),
            (heroChill - 0.12, .mark(.tab(.tuned)), false),
            (heroChill - 0.05, .mark(.tab(.tuned)), true),
            (heroChill + 0.1, .mark(.tab(.tuned)), false),
            // Held on the tab until the cut's crossfade is over (the knob is
            // only on screen once the frame is chill's alone), then onto the
            // knob before the stage goes inside, resting there while it does.
            (heroChill + fade + 0.05, .mark(.tab(.tuned)), false),
            (heroChill + 0.65, .handle, false),
            (heroPushAt - 0.05, .handle, false),
            (heroPushAt, .handle, true),
            (heroPushAt + 0.8, .handle, true),
            (heroPushAt + 0.9, .handle, false),
            (heroPushAt + 1.6, .at(outside), false),
        ])

    /// One frame of the hero's machine: its heat and the fans' rpm.
    struct Moment {
        let heat: Heat
        let rpm: [Double]
    }

    /// The hero's heat at every frame: an idle Mac, settled, then a long load
    /// from 0.8 s; the chip stepped by `Heat`, the fans by the demo daemon's
    /// physics under the story's tab, in the order `render` steps them, so
    /// the fans this predicts are the ones the clip draws.
    static let heroHeat: [Moment] = {
        var heat = Heat()
        for _ in 0..<600 { heat.step(load: 0, air: 0, seconds: 0.1) }
        var world = World()
        for _ in 0..<Int(10 * fps) {
            world.step(
                die: heat.cpu, intent: World.intent(heroUI(0).tab, push: heroPush(0)),
                watching: true, seconds: 1 / fps)
        }
        return (0...Int(heroClip * fps)).map { i in
            let t = Double(i) / fps
            let now = heat
            world.step(
                die: now.cpu, intent: World.intent(heroUI(t).tab, push: heroPush(t)),
                watching: true, seconds: 1 / fps)
            heat.step(
                load: t < 0.8 ? 0 : 1, air: Heat.air(world.actual, fans: FakeDaemon.fans),
                seconds: 1 / fps)
            return Moment(heat: now, rpm: world.actual)
        }
    }()

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
        path: [(0, .at(outside), false)])

    // MARK: - the world

    /// The demo daemon's fans and its verdicts, stepped on the film's clock
    /// with the same physics (`FakeDaemon.target`, `slew`, `holder`,
    /// `reason`), so the film shows what the demo world does.
    @MainActor struct World {
        var actual = FakeDaemon.fans.map { _ in 0.0 }

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

    /// Renders `story` into `out` (H.264) and returns the popover's size in
    /// points.
    static func render(_ story: Story, model: Model, out: URL) -> CGSize {
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
                return draw(model, story: story, t: t)
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

    private static func draw(_ model: Model, story: Story, t: Double) -> CGImage {
        let renderer = ImageRenderer(content: SurfaceFrame(model: model, story: story, t: t))
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
/// background, the size SwiftUI lays it out at, and the pointer the story
/// moves over it (the frame's edge cuts it where it leaves for the desktop).
struct SurfaceFrame: View {
    let model: Model
    let story: Film.Story
    let t: Double

    var body: some View {
        PopoverView(model: model)
            .background(Color(nsColor: .windowBackgroundColor))
            .overlayPreferenceValue(FilmMarks.self) { marks in
                GeometryReader { proxy in pointer(marks, proxy) }
            }
            .environment(\.colorScheme, .dark)
            .environment(\.locale, .figures)
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
