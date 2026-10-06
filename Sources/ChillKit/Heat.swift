import Foundation

/// The demo world's heat, the stage's thermal story: a chip under load, the
/// parts around it and the case's skin, cooled only as fast as the fans move
/// air. Dramatized for the stage, every time constant in story seconds where
/// a real Mac takes minutes, so a scene tells in twenty seconds what a palm
/// feels over ten minutes; the ORDER is real: the chip in a moment, the gpu
/// and ssd after it, the battery under the palm rest slower, the skin last.
/// The fans' rpm comes from the demo daemon's physics (`FakeDaemon.target`,
/// `slew`), so Apple's curve here is the one the demo plays everywhere.
public struct Heat: Sendable, Equatable {
    public var cpu = 48.0
    public var gpu = 45.0
    public var ssd = 37.0
    public var battery = 31.0
    /// The case's skin, what a palm feels: no sensor reports it, so it is
    /// modelled from the chip and the battery under it, held down by air.
    public var skin = 30.0

    public init() {}

    /// Seconds for each part to go most of the way to where it is heading.
    static let tau = (cpu: 1.2, gpu: 1.6, ssd: 3.5, battery: 3.0, skin: 3.0)

    /// One step: `load` 0 (idle) to 1 (a long render), `air` how hard the
    /// fans blow, 0 (off) to 1 (both at their ceiling).
    public mutating func step(load: Double, air: Double, seconds: Double) {
        func toward(_ v: Double, _ target: Double, _ tau: Double) -> Double {
            v + (target - v) * (1 - exp(-seconds / tau))
        }
        cpu = toward(cpu, 46 + 55 * load - 30 * air, Heat.tau.cpu)
        gpu = toward(gpu, 44 + 40 * load - 22 * air, Heat.tau.gpu)
        ssd = toward(ssd, 36 + 12 * load - 4 * air, Heat.tau.ssd)
        battery = toward(battery, 31 + 0.3 * (cpu - 46) - 3 * air, Heat.tau.battery)
        skin = toward(
            skin, 30 + 0.2 * (cpu - 46) + 0.45 * (battery - 31) - 6 * air, Heat.tau.skin)
    }

    /// How hard the fans blow at these rpm: each one's share of its ceiling
    /// (off is 0), the mean of them.
    public static func air(_ rpm: [Double], fans: [Fan]) -> Double {
        zip(rpm, fans).map { $0 / $1.max }.reduce(0, +) / Double(max(1, fans.count))
    }
}
