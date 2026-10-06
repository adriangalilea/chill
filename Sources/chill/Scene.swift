import AppKit
import ChillKit
import SwiftUI

/// `chill --demo scene --cdn <url> --films <dir> --out <dir>...`: chill's
/// stories as `@ag/macos` timelines, the stage the garden plays on a
/// MacBook. The app owns every pixel and word on it: the glyph states are
/// `Glyph`'s own renders, every status line is `Status.line` over the demo
/// world's state, every refusal and note the CLI's own constant, and the
/// popover is a surface clip the film engine renders (`Film`, surface
/// cut) into `--films`, published at `--cdn`. Writes `art.json`,
/// `hero.json`, `walk-away.json` and `cli.json` into every `--out`.
@MainActor
enum Scene {
    /// No clock and no date: chill's stories take no time worth naming, so
    /// the stage shows the viewer's own.
    struct World: Encodable {
        var battery = 76
        var charging = false
        var lid = "open"
        var asleep = false
        var heat = false
        var locked: Bool? = nil
    }

    struct Step: Encodable {
        let kind: String
        var author: Bool? = nil
        var delay: Int? = nil
        var text: String? = nil
        var glyph: String? = nil
        var tooltip: String? = nil
        var keys: String? = nil
        var world: World? = nil
        var arg: String? = nil
        var thermal: Reading? = nil
        var depth: Double? = nil
    }

    /// The machine's heat as `@ag/thermal` reads it: each part's °C, the
    /// skin, each fan's share of its ceiling (off is 0).
    struct Reading: Encodable {
        let parts: [String: Double]
        let surface: Double
        let fans: [Double]

        init(_ heat: Heat, rpm: [Double]) {
            let round = { (c: Double) in (c * 10).rounded() / 10 }
            parts = [
                "cpu": round(heat.cpu), "gpu": round(heat.gpu), "ssd": round(heat.ssd),
                "battery": round(heat.battery),
            ]
            surface = round(heat.skin)
            fans = zip(rpm, FakeDaemon.fans).map { ($0 / $1.max * 1000).rounded() / 1000 }
        }
    }

    struct Timeline: Encodable {
        let app = "chill"
        let chord: String
        let steps: [Step]
    }

    struct Pair: Encodable {
        let light: String
        let dark: String
    }

    struct Surface: Encodable {
        let src: String
        let poster: String
        let width: Double
        let height: Double
        let background: String
    }

    struct Art: Encodable {
        let icon: String
        let glyphs: [String: Pair]
        let surfaces: [String: Surface]
    }

    static func run(_ args: [String]) -> Never {
        func values(_ flag: String) -> [String] {
            args.indices.filter { args[$0] == flag && $0 + 1 < args.count }.map { args[$0 + 1] }
        }
        guard let cdn = values("--cdn").first, let dir = values("--films").first,
            !values("--out").isEmpty
        else {
            Verbs.die("usage: chill --demo scene --cdn <url> --films <dir> --out <dir>...")
        }
        let outs = values("--out").map { URL(fileURLWithPath: $0) }
        let model = Film.model()

        // Each popover a scene opens, as its own clip and its poster.
        let films = URL(fileURLWithPath: dir)
        let clips: [(String, Film.Story)] = [("hero", Film.hero), ("walk-away", Film.walkAway)]
        var surfaces: [String: Surface] = [:]
        for (name, story) in clips {
            let clip = films.appending(path: "\(name).mp4")
            let size = Film.render(story, model: Film.model(), out: clip)
            still(clip, into: films.appending(path: "\(name).jpg"))
            surfaces[name] = Surface(
                src: "\(cdn)/\(name).mp4", poster: "\(cdn)/\(name).jpg",
                width: size.width, height: size.height, background: Film.background)
            print("scene: \(clip.path) (\(Int(size.width))×\(Int(size.height)) pt)")
        }

        let art = Art(
            icon: dataURL(png: icon()),
            glyphs: Dictionary(
                uniqueKeysWithValues: [Glyph.outline, .filled, .bar, .slashed, .dotted].map {
                    (
                        "\($0)",
                        Pair(
                            light: dataURL(png: png($0, .aqua)),
                            dark: dataURL(png: png($0, .darkAqua)))
                    )
                }),
            surfaces: surfaces)
        let chord = model.store.displayPrimary(for: .toggle)
        let files: [(String, any Encodable)] = [
            ("art.json", art),
            ("hero.json", Timeline(chord: chord, steps: hero())),
            ("walk-away.json", Timeline(chord: chord, steps: walkAway())),
            ("cli.json", Timeline(chord: chord, steps: cli())),
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        for out in outs {
            do {
                try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
                for (name, value) in files {
                    try encoder.encode(value).write(to: out.appending(path: name))
                }
            } catch {
                Verbs.die("scene: \(out.path): \(error)")
            }
            print("scene: \(out.path)/{\(files.map(\.0).joined(separator: ","))}")
        }
        exit(0)
    }

    // MARK: - the stories

    /// The value in one breath, a hot Mac in four acts, the popover open from
    /// the first frame (`Film.hero`) and the machine's heat in the stage's
    /// MacBook, both from one simulation (`Film.heroHeat`):
    ///   1. under a long load on Apple's curve, the MacBook heats up (the skin);
    ///   2. the pointer presses chill, the view still;
    ///   3. the stage goes inside, the pointer resting on the knob; once in,
    ///      it pushes the knob and the fans answer;
    ///   4. every part cools.
    /// Then the end is a moment, not an act: the popover closes and the view
    /// comes back out to the case, still cooling, and the story stops. No
    /// frame is ever held still. The pointer and the view never move
    /// together: one thing at a time. Each act is a chapter its caption
    /// closes, in words, no figures: the picture carries the numbers. The
    /// glyph flips on the clip's own cut; the poster is act 3.
    /// Readings every quarter second; the stage glides between. Captions are
    /// not author steps: they land on the story's clock and never hold it
    /// for reading, so the stage stays frame for frame with the clip, and
    /// each is short enough to read inside its act.
    static func hero() -> [Step] {
        let heat = Film.heroHeat
        let at = { (t: Double) in heat[min(heat.count - 1, Int((t * Film.fps).rounded()))] }
        let curve = Film.World.intent(.tuned, push: Film.heroPush(Film.heroChill))
        // The acts' ends, in story seconds: where each caption closes one and
        // the view changes for the next.
        let acts = (
            heats: 3.0, press: Film.heroChill + 0.75, push: Film.heroPushAt + 1.05, cools: 8.0
        )
        // What happens when, in story seconds, and in which order at one
        // instant: a caption closes its act before the next act's change.
        var events: [(t: Double, rank: Int, step: Step)] =
            stride(from: 0.25, through: Film.heroLength, by: 0.25).map { t in
                let m = at(t)
                let depth: Double? =
                    switch t {
                    case 0.25: 1
                    case acts.press: 2
                    case acts.cools: 1
                    default: nil
                    }
                return (
                    t, 1,
                    Step(kind: "thermal", thermal: Reading(m.heat, rpm: m.rpm), depth: depth)
                )
            }
        let caption = { (t: Double, text: String) in
            (t, 0, Step(kind: "caption", text: text))
        }
        let hot = at(Film.heroChill)
        events += [
            caption(acts.heats, "Your MacBook heats up"),
            caption(acts.press, "Press chill"),
            caption(acts.push, "The fans spin up"),
            caption(acts.cools, "Everything cools down"),
            // The end: chill's popover closes as the view comes back out.
            (acts.cools, 1, Step(kind: "close")),
            (
                Film.heroChill, 1,
                Step(
                    kind: "glyph", glyph: "filled",
                    tooltip: line(die: hot.heat.cpu, intent: curve, watching: true))
            ),
            (acts.push + 0.5, 1, Step(kind: "poster")),
        ]
        var steps = [
            Step(kind: "world", author: true, world: World()),
            Step(
                kind: "glyph", glyph: "outline",
                tooltip: line(die: at(0).heat.cpu, intent: .system, watching: true)),
            Step(kind: "surface", text: "hero", arg: "0"),
            Step(kind: "thermal", thermal: Reading(at(0).heat, rpm: at(0).rpm)),
        ]
        var last = 0.0
        for (t, _, step) in events.sorted(by: { ($0.t, $0.rank) < ($1.t, $1.rank) }) {
            var s = step
            s.delay = Int(((t - last) * 1000).rounded())
            steps.append(s)
            last = t
        }
        return steps
    }

    /// Lock the Mac and walk away: the popover shows chill holding the fans;
    /// the lock screen comes up; unlocked, the popover opens on the fans at
    /// Apple's curve (the drop in the afterglow) a beat before the watcher
    /// is back, and the curve takes them again.
    static func walkAway() -> [Step] {
        let die = Film.walkAway.die(0)
        let push = Film.walkAway.push(0)
        let curve = Film.World.intent(.tuned, push: push)
        let reopen = Film.back - 0.8
        return [
            Step(kind: "world", author: true, world: World()),
            Step(
                kind: "glyph", glyph: "filled",
                tooltip: line(die: die, intent: curve, watching: true)),
            Step(kind: "surface", text: "walk-away", arg: "\(Film.holding)"),
            Step(
                kind: "caption", author: true,
                text: "chill runs your fan curve while you're at the Mac"),
            Step(kind: "poster"),
            // A caption titles what came before it, as awake's scenes do.
            Step(kind: "world", author: true, world: World(locked: true)),
            Step(kind: "caption", author: true, text: "Lock the screen and walk away"),
            Step(
                kind: "glyph", glyph: "outline",
                tooltip: line(die: die, intent: curve, watching: false)),
            Step(kind: "caption", author: true, text: "Within ten seconds, Apple has the fans"),
            Step(kind: "world", author: true, world: World()),
            Step(kind: "surface", author: true, text: "walk-away", arg: "\(reopen)"),
            Step(
                kind: "glyph", delay: Int((Film.back - reopen) * 1000), glyph: "filled",
                tooltip: line(die: die, intent: curve, watching: true)),
            Step(
                kind: "caption", author: true, text: "Back at the Mac, your curve takes them again"),
        ]
    }

    /// The same rules in a terminal: nothing forces a fan without a
    /// watcher, `--watch` makes the terminal one, Ctrl-C hands back.
    static func cli() -> [Step] {
        let die = 42.0
        let quiet = Demo.seedCurves.first { $0.name == "quiet" }!
        let boost = Intent.boost(until: Date.now.addingTimeInterval(4 * 60 + 58))
        let watch = Role.watch.rawValue
        return [
            Step(kind: "world", author: true, world: World()),
            Step(
                kind: "glyph", glyph: "outline",
                tooltip: line(die: die, intent: .system, watching: false)),
            // A caption titles what came before it, as awake's scenes do.
            Step(kind: "command", author: true, text: "chill status"),
            Step(kind: "output", text: line(die: die, intent: .system, watching: false)),
            Step(kind: "command", author: true, text: "chill curve use quiet"),
            Step(kind: "output", text: Verbs.said(Verbs.noWatcher)),
            Step(
                kind: "caption", author: true,
                text: "On its own, a curve changes nothing"),
            Step(kind: "poster"),
            Step(kind: "command", author: true, text: "chill curve use quiet --watch"),
            Step(kind: "muted", text: Watch.greeting),
            Step(
                kind: "output",
                text: line(die: die, intent: .curve(quiet), watching: true, name: watch)),
            Step(
                kind: "glyph", glyph: "filled",
                tooltip: line(die: die, intent: .curve(quiet), watching: true, name: watch)),
            Step(
                kind: "caption", author: true,
                text: "--watch holds the fans while the terminal runs"),
            Step(kind: "key", author: true, keys: "⌃C"),
            Step(kind: "muted", text: "^C"),
            Step(kind: "output", text: line(die: die, intent: .system, watching: false)),
            Step(
                kind: "glyph", glyph: "outline",
                tooltip: line(die: die, intent: .system, watching: false)),
            Step(kind: "caption", author: true, text: "Ctrl-C hands the fans back"),
            Step(kind: "command", author: true, text: "chill boost 5 --watch"),
            Step(kind: "muted", text: Watch.greeting),
            Step(kind: "output", text: line(die: die, intent: boost, watching: true, name: watch)),
            Step(
                kind: "glyph", glyph: "bar",
                tooltip: line(die: die, intent: boost, watching: true, name: watch)),
            Step(kind: "caption", author: true, text: "A boost runs flat out, then ends by itself"),
        ]
    }

    /// `chill status` for the demo world settled at `die` under `intent`.
    static func line(die: Double, intent: Intent, watching: Bool, name: String = Role.app.rawValue)
        -> String
    {
        var world = Film.World()
        for _ in 0..<Int(10 * Film.fps) {
            world.step(die: die, intent: intent, watching: watching, seconds: 1 / Film.fps)
        }
        return Status.line(world.state(die: die, intent: intent, watching: watching, name: name))
    }

    // MARK: - the pixels

    /// A glyph state as a menu bar in `appearance` draws it, at 2x: its own
    /// colors, resolved for that bar.
    static func png(_ glyph: Glyph, _ appearance: NSAppearance.Name) -> Data {
        let side = Int(Glyph.side * 2)
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: Glyph.side, height: Glyph.side)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
            glyph.image().draw(in: NSRect(x: 0, y: 0, width: Glyph.side, height: Glyph.side))
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    /// The app icon, the one `mise icon` renders from `scripts/icon.svg`.
    static func icon() -> Data {
        let path = "Resources/icon.png"
        guard let data = FileManager.default.contents(atPath: path) else {
            Verbs.die("scene: no \(path): run from the chill checkout after `mise icon`")
        }
        return data
    }

    static func dataURL(png: Data) -> String {
        "data:image/png;base64,\(png.base64EncodedString())"
    }

    /// The clip's first frame as the surface's poster.
    static func still(_ clip: URL, into poster: URL) {
        let ffmpeg = Process()
        ffmpeg.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        ffmpeg.arguments = [
            "ffmpeg", "-loglevel", "error", "-y", "-i", clip.path, "-frames:v", "1", "-q:v", "2",
            poster.path,
        ]
        do { try ffmpeg.run() } catch { Verbs.die("scene: ffmpeg: \(error)") }
        ffmpeg.waitUntilExit()
        guard ffmpeg.terminationStatus == 0 else {
            Verbs.die("scene: ffmpeg exited \(ffmpeg.terminationStatus) on \(poster.path)")
        }
    }
}
