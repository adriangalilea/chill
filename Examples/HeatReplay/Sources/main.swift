import ChillKit
import Foundation

// heat-replay trace <sensors.jsonl> <curve.json> [--min rpm] [--max rpm] [--csv out]
// heat-replay log <chilld.log> <curve.json> [--since <iso>] [--min rpm] [--max rpm] [--csv out]
//
// trace: `chill sensors --follow --json`, the die per line (`die`, else the
//   hottest of `cpu` and `gpu`).
// log: chilld's log, its `fan 0: target a -> b` lines read back through the
//   curve into the heat that asked for each target (the curve is monotone);
//   a stretch the log says nothing about held at the last value, a target at
//   the curve's floor read as the floor's end, the coolest it can have been.
//
// Either way, one sample a second through two inputs, the raw die (what
// chill followed before) and `Heat.follow` (what it follows now), each into
// the curve, the writer's 50 rpm hysteresis, and the fans slewed by the demo
// daemon's physics (`FakeDaemon.slew`). Printed per input: target writes a
// minute, target jumps over 1000 rpm a minute, fan reversals over 500 rpm a
// minute (the square: up, hold, down), and the mean rpm (what it costs).

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data("heat-replay: \(message)\n".utf8))
    exit(1)
}

var args = Array(CommandLine.arguments.dropFirst())
func flag(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let value = args[i + 1]
    args.removeSubrange(i...i + 1)
    return value
}
let since = flag("--since").map { value -> Date in
    guard let date = ISO8601DateFormatter().date(from: value) else { die("--since \(value) is no ISO 8601 date") }
    return date
}
let low = flag("--min").map { Double($0)! } ?? 2317
let high = flag("--max").map { Double($0)! } ?? 7826
let csv = flag("--csv")
guard args.count == 3, ["trace", "log"].contains(args[0]) else {
    die("usage: heat-replay trace|log <file> <curve.json> [--since iso] [--min rpm] [--max rpm] [--csv out]")
}
let fan = Fan(index: 0, min: low, max: high)
let curve: Curve
do {
    curve = try Wire.decode(Curve.self, from: Data(contentsOf: URL(filePath: args[2])))
} catch {
    die("\(args[2]): \(error)")
}
let text: String
do { text = try String(contentsOf: URL(filePath: args[1]), encoding: .utf8) } catch { die("\(args[1]): \(error)") }

/// The temperature that asked for `rpm` under the curve: bisection, the
/// curve being monotone; the floor reads as the floor's end.
func celsius(asking rpm: Double) -> Double {
    var (lo, hi) = (0.0, 130.0)
    for _ in 0..<60 {
        let mid = (lo + hi) / 2
        if curve.target(at: mid, for: fan) < rpm { lo = mid } else { hi = mid }
    }
    return hi
}

/// One die reading a second.
let dies: [Double] = {
    switch args[0] {
    case "trace":
        struct Line: Decodable {
            let die: Double?
            let cpu: Double?
            let gpu: Double?
        }
        return text.split(separator: "\n").compactMap { row in
            guard let line = try? JSONDecoder().decode(Line.self, from: Data(row.utf8)) else {
                die("a trace line does not parse: \(row)")
            }
            return line.die ?? [line.cpu, line.gpu].compactMap { $0 }.max()
        }
    default:
        let format = ISO8601DateFormatter()
        var points: [(Date, Double)] = []
        for row in text.split(separator: "\n") {
            let words = row.split(separator: " ")
            guard words.count == 7, words[1] == "fan", words[2] == "0:", words[3] == "target",
                let at = format.date(from: String(words[0])), let rpm = Double(words[6])
            else { continue }
            if let since, at < since { continue }
            points.append((at, celsius(asking: rpm)))
        }
        guard let first = points.first else { die("no `fan 0: target` lines in \(args[1])") }
        var out: [Double] = []
        var next = 0
        var held = first.1
        var t = first.0
        while t <= points.last!.0 {
            while next < points.count, points[next].0 <= t {
                held = points[next].1
                next += 1
            }
            out.append(held)
            t += 1
        }
        return out
    }
}()
guard dies.count > 60 else { die("\(dies.count) seconds: too short to judge") }

struct Run {
    var writes = 0
    var jumps = 0
    var reversals = 0
    var rpmSum = 0.0
    var targets: [Double] = []
    var fans: [Double] = []
}

/// One input through the curve, the writer and the fan.
func replay(_ input: [Double]) -> Run {
    var run = Run()
    var written: Double?
    var actual = curve.target(at: input[0], for: fan)
    // The fan's last turning point and which way it has gone since: a
    // reversal is the fan coming back 500 rpm from its last extreme.
    var extreme = actual
    var rising: Bool?
    for c in input {
        let asked = curve.target(at: c, for: fan)
        if written.map({ abs($0 - asked) >= 50 }) ?? true {
            if let written, abs(written - asked) > 1000 { run.jumps += 1 }
            written = asked
            run.writes += 1
        }
        actual = FakeDaemon.slew(actual, toward: written!, seconds: 1)
        switch rising {
        case true?:
            if actual > extreme {
                extreme = actual
            } else if extreme - actual >= 500 {
                run.reversals += 1
                (rising, extreme) = (false, actual)
            }
        case false?:
            if actual < extreme {
                extreme = actual
            } else if actual - extreme >= 500 {
                run.reversals += 1
                (rising, extreme) = (true, actual)
            }
        case nil:
            if abs(actual - extreme) >= 500 { (rising, extreme) = (actual > extreme, actual) }
        }
        run.rpmSum += actual
        run.targets.append(written!)
        run.fans.append(actual)
    }
    return run
}

var heat: Double?
let heats = dies.map { d -> Double in
    heat = Heat.follow(heat, die: d, seconds: 1)
    return heat!
}
let minutes = Double(dies.count) / 60
let raw = replay(dies)
let followed = replay(heats)
print(String(format: "%@ · %.0f min · curve \"%@\" · fans %.0f..%.0f rpm", args[0], minutes, curve.name, low, high))
print("                    raw die   Heat.follow")
func row(_ name: String, _ a: Double, _ b: Double, _ format: String = "%9.1f") {
    print(name.padding(toLength: 18, withPad: " ", startingAt: 0) + String(format: format, a) + "  " + String(format: format, b))
}
row("writes/min", Double(raw.writes) / minutes, Double(followed.writes) / minutes)
row("jumps>1000/min", Double(raw.jumps) / minutes, Double(followed.jumps) / minutes, "%9.2f")
row("reversals/min", Double(raw.reversals) / minutes, Double(followed.reversals) / minutes, "%9.2f")
row("mean rpm", raw.rpmSum / Double(dies.count), followed.rpmSum / Double(dies.count), "%9.0f")
if let csv {
    var out = "t,die,heat,raw_target,raw_fan,heat_target,heat_fan\n"
    for i in dies.indices {
        out += String(
            format: "%d,%.2f,%.2f,%.0f,%.0f,%.0f,%.0f\n", i, dies[i], heats[i], raw.targets[i],
            raw.fans[i], followed.targets[i], followed.fans[i])
    }
    do { try out.write(toFile: csv, atomically: true, encoding: .utf8) } catch { die("\(csv): \(error)") }
}
