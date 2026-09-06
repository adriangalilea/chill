import Foundation

/// Why the fans are where they are, in the words `chill status` prints
/// after the intent. Every daemon (chilld and the demo's in-process one)
/// derives it from the read-back on every evaluation and ships it as
/// `State.lastReason`; the CLI prints it as is and appends what the
/// reason itself cannot know (the boost's remaining time).
public enum Reason: CustomStringConvertible, Equatable, Sendable {
    case apple
    case foreign
    case vetoed(Veto)
    case noOneWatching
    case acquiring
    case curve(String)
    /// The curve runs but asks no more than the fan's floor, so chill has
    /// not taken the fan: Apple holds it until the curve rises.
    case floor(String)
    /// Carries no number: the rpm printed after it is the read-back, never
    /// the cached envelope max.
    case boost
    case noFans
    /// A fan the last pass could not read; the log has the error.
    case unreadable(fan: Int)
    /// A fan chill holds (mode 1 read back) whose target write the firmware
    /// answered with a result byte AND the read-back did not match: the
    /// fan is chill's, the number is not.
    case targetRefused(fan: Int, result: UInt8)

    public var description: String {
        switch self {
        case .apple: return "Apple's curve"
        case .foreign: return "forced by someone else · `chill system` reclaims"
        case .vetoed(let veto): return "vetoed: \(veto.spelled) · Apple holds the fans"
        case .noOneWatching: return "no one watching → Apple holds the fans"
        case .acquiring: return "acquiring"
        case .curve(let name): return "curve \"\(name)\""
        case .floor(let name): return "curve \"\(name)\" at its floor · Apple holds the fans"
        case .boost: return "max rpm"
        case .noFans: return "this Mac has no fans"
        case .unreadable(let fan): return "smc: fan \(fan) unreadable · see chilld.log"
        case .targetRefused(let fan, let result):
            return "smc: fan \(fan) target refused 0x\(String(result, radix: 16)) · see chilld.log"
        }
    }
}

extension Veto {
    /// Status order: the veto named first is the one that explains the most.
    public static let order: [Veto] = [.lid, .sleep, .thermal, .noReading]

    public var spelled: String {
        switch self {
        case .lid: return "lid closed"
        case .sleep: return "sleep"
        case .thermal: return "thermal pressure"
        case .noReading: return "no reading"
        }
    }
}
