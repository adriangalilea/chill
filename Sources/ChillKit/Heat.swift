import Foundation

/// What a curve follows: the heat in the chip's cooler, not its spikes.
///
/// A die sensor answers two things at once. Power first: the moment work
/// starts the chip reads several degrees over its cooler, within a second
/// or two, and drops back the moment it stops (an M5 Max under every core:
/// 45 to 57 °C in 4 s, 73 to 65 °C in 4 s). Heat second: the cooler and the
/// chassis warming under that power and cooling after it, which the fans
/// move, a time constant of about 45 s at Apple's idle fans (the same M5
/// Max's unloaded gpu, which reads the shared cooler, cooling 65 to 47 °C).
/// A curve fed the raw reading turns every burst of work into a fan that
/// spins up for the burst and down after it, the square a person hears.
///
/// So the curve's input follows the die the way heat does: up with the
/// geometric mean of the two time scales (`rise`, slow enough that a burst
/// barely moves it, quick enough to meet a real load in seconds), down at
/// the cooler's own pace (`fall`: the reading drops at once, the heat leaves
/// the chassis no faster than the cooler sheds it, and the fans follow the
/// heat). One function for the daemon that writes the fans, the demo's
/// daemon, the app reading the sensors itself, and the replay that proves
/// it; a step longer than both constants simply lands.
public enum Heat {
    /// How fast the chip's own jump over its cooler settles.
    public static let chipSettles = 1.5
    /// The cooler's time constant at Apple's idle fans.
    public static let coolerSheds = 45.0
    public static let rise = (chipSettles * coolerSheds).squareRoot()
    public static let fall = coolerSheds

    /// The heat after `seconds` more of a die reading `die`, from `heat`
    /// (nil: the first reading, which is taken as it is).
    public static func follow(_ heat: Double?, die: Double, seconds: Double) -> Double {
        precondition(seconds >= 0, "heat: \(seconds) s since the last reading")
        guard let heat else { return die }
        let tau = die > heat ? rise : fall
        return heat + (die - heat) * (1 - exp(-seconds / tau))
    }
}
