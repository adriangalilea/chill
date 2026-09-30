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
                            light: dataURL(png: png($0, .black)),
                            dark: dataURL(png: png($0, .white)))
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

    /// The value in one breath, the popover open from the first frame: the
    /// pointer presses chill and pushes the knob as the heat arrives, the
    /// fans ride the curve, it presses apple. The glyph flips at the clip's
    /// own cuts, so the menu bar and the popover change on the same frame;
    /// the poster is the climb at its peak, the afterglow behind it.
    static func hero() -> [Step] {
        let story = Film.hero
        let (on, off) = (story.cuts[0], story.cuts[1])
        let peak = 11.0
        let ms = { (seconds: Double) in Int((seconds * 1000).rounded()) }
        let idle = line(die: story.die(0), intent: .system, watching: true)
        let curve = line(
            die: story.die(peak), intent: Film.World.intent(.tuned, push: story.push(peak)),
            watching: true)
        return [
            Step(kind: "world", author: true, world: World()),
            Step(kind: "glyph", glyph: "outline", tooltip: idle),
            Step(kind: "surface", text: "hero", arg: "0"),
            Step(kind: "glyph", delay: ms(on), glyph: "filled", tooltip: curve),
            Step(kind: "poster", delay: ms(peak - on)),
            Step(
                kind: "glyph", delay: ms(off - peak), glyph: "outline",
                tooltip: line(die: story.die(off), intent: .system, watching: true)),
            // The clip's last seconds: the fans settle on Apple's curve.
            Step(kind: "world", delay: ms(story.length - off), world: World()),
        ]
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

    /// A glyph state as the menu bar draws it: the template in `ink`, at 2x.
    static func png(_ glyph: Glyph, _ ink: NSColor) -> Data {
        let template = glyph.image()
        let side = Int(Glyph.side * 2)
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: Glyph.side, height: Glyph.side)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let rect = NSRect(x: 0, y: 0, width: Glyph.side, height: Glyph.side)
        template.draw(in: rect)
        ink.set()
        rect.fill(using: .sourceAtop)
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
