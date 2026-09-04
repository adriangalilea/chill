import ChillKit
import Foundation
import MachSensors

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

    /// No SMC = no local telemetry at all (thrown); no HID = fans without a
    /// die, said once on stderr like chilld logs it once.
    init() throws {
        smc = try SMC()
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
}
