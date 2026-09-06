import ChillKit
import Foundation
import MachSensors

enum LocalSensorsError: Error, CustomStringConvertible {
    case envelope(fan: Int, min: Double, max: Double)

    var description: String {
        switch self {
        case .envelope(let fan, let min, let max):
            return "smc: fan \(fan) reports envelope \(min)..\(max) rpm, not positive and ordered"
        }
    }
}

/// What the machine reads without a daemon: the hottest die and the fans
/// as the SMC reports them, through the read-only package (no write
/// function exists in it). The canvas draws these markers only while no
/// daemon answers; with one, `State` is the single source.
struct LocalSample {
    let die: Double?
    let fans: [FanReading]
}

final class LocalSensors {
    private let smc: SMC
    private let hid: HIDSensors?
    /// The fans' reported envelope, lowest Mn to highest Mx, read ONCE
    /// here exactly as chilld's writer reads it: `Mx` reads intermittently,
    /// so it never rides the 1 Hz sample. nil on a fanless Mac.
    let envelope: ClosedRange<Double>?

    /// No SMC = no local telemetry at all (thrown); no HID = fans without a
    /// die, said once on stderr like chilld logs it once.
    init() throws {
        smc = try SMC()
        var span: ClosedRange<Double>?
        for fan in try smc.fans() {
            let reported = try smc.envelope(fan: fan.index)
            guard reported.min > 0, reported.min < reported.max else {
                throw LocalSensorsError.envelope(
                    fan: fan.index, min: reported.min, max: reported.max)
            }
            span =
                span.map {
                    Swift.min($0.lowerBound, reported.min)...Swift.max($0.upperBound, reported.max)
                } ?? reported.min...reported.max
        }
        envelope = span
        do {
            hid = try HIDSensors()
        } catch {
            Verbs.note("chill: \(error); the canvas has no die marker without a daemon")
            hid = nil
        }
    }

    func sample() -> LocalSample {
        LocalSample(
            die: hid?.hottest()?.celsius,
            fans: (try? smc.fans()) ?? [])
    }

    /// Every thermal sensor the machine names, for the temperature badge:
    /// the die's spots and the few with a real name (ssd, battery).
    func temperatures() -> [Sensor] {
        hid?.readings() ?? []
    }
}
