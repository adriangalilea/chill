import ChillKit
import Foundation
import MachSensors

/// `chill sensors [--follow] [--json]`: what this Mac reads, straight from
/// the read-only package (no daemon, no root): the hottest die and the heat
/// a curve follows from it (`Heat.follow`, as chilld computes it), the
/// hottest sensor of each named part, the ssd and the battery, and the fans
/// as the SMC reports them. `--follow` prints a line a second until Ctrl-C,
/// the trace a curve is judged against; `--json` one object per line.
@MainActor
final class SensorsVerb {
    struct Line: Encodable {
        let t: Double
        let die: Double?
        let heat: Double?
        let cpu: Double?
        let gpu: Double?
        let memory: Double?
        let ssd: Double?
        let battery: Double?
        let rpm: [Double]
    }

    private let sensors: LocalSensors
    private let json: Bool
    private let started = ContinuousClock.now
    private var last: LocalSample?
    private var timer: DispatchSourceTimer?

    private init(sensors: LocalSensors, json: Bool) {
        self.sensors = sensors
        self.json = json
    }

    static func run(_ args: [String], demo: Demo) -> Never {
        if demo.on { Verbs.die("sensors: this Mac's sensors only, never the demo world") }
        let follow = args.contains("--follow")
        let json = args.contains("--json")
        guard args.allSatisfy({ $0 == "--follow" || $0 == "--json" }) else {
            Verbs.die("usage: chill sensors [--follow] [--json]")
        }
        let verb: SensorsVerb
        do {
            verb = SensorsVerb(sensors: try LocalSensors(), json: json)
        } catch {
            Verbs.die("\(error)")
        }
        if !json { print("     s   die  heat   cpu   gpu   mem   ssd  batt  rpm") }
        verb.say()
        guard follow else { exit(0) }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { MainActor.assumeIsolated { verb.say() } }
        timer.resume()
        verb.timer = timer
        dispatchMain()
    }

    private func say() {
        let sample = sensors.sample(after: last)
        last = sample
        let parts = Dictionary(
            uniqueKeysWithValues: sensors.partReadings().map { ($0.group, $0.celsius.max()) })
        let named = Dictionary(
            uniqueKeysWithValues: Badge.named(sensors.temperatures()).map { ($0.name, $0.celsius) })
        let line = Line(
            t: ((sample.at - started).seconds * 10).rounded() / 10, die: sample.die,
            heat: sample.heat, cpu: parts[.cpu] ?? nil, gpu: parts[.gpu] ?? nil,
            memory: parts[.memory] ?? nil, ssd: named["ssd"], battery: named["battery"],
            rpm: sample.fans.map(\.actual))
        if json {
            print(String(decoding: Wire.encode(line), as: UTF8.self))
        } else {
            func c(_ v: Double?) -> String { v.map { String(format: "%6.1f", $0) } ?? "     -" }
            let rpm = line.rpm.map { String(format: "%5.0f", $0) }.joined(separator: " ")
            print(
                String(format: "%6.1f", line.t) + c(line.die) + c(line.heat) + c(line.cpu)
                    + c(line.gpu) + c(line.memory) + c(line.ssd) + c(line.battery) + "  " + rpm)
        }
        fflush(stdout)
    }
}
