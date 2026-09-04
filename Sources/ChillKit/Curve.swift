import Foundation

/// A fan runs a curve: temperature in, rpm out. That is the whole model.
/// One curve serves every fan; each fan clamps the result to its own
/// envelope. A constant rpm is a one-point curve; boost is a curve pinned
/// at max. Points are held sorted by temperature, and a decoded curve is
/// validated exactly like a constructed one, so no `Curve` exists that
/// `rpm(at:)` cannot evaluate.
public struct Curve: Codable, Sendable, Hashable {
    public struct Point: Codable, Sendable, Hashable {
        public let c: Double
        public let rpm: Double

        public init(c: Double, rpm: Double) {
            self.c = c
            self.rpm = rpm
        }
    }

    public let name: String
    public let points: [Point]

    public init(name: String, points: [Point]) throws {
        guard !name.isEmpty else { throw CurveError.unnamed }
        guard !points.isEmpty else { throw CurveError.noPoints(name) }
        let sorted = points.sorted { $0.c < $1.c }
        for (a, b) in zip(sorted, sorted.dropFirst()) where a.c == b.c {
            throw CurveError.duplicateTemperature(name, a.c)
        }
        if let bad = sorted.first(where: { $0.rpm < 0 }) {
            throw CurveError.negativeRPM(name, bad.rpm)
        }
        self.name = name
        self.points = sorted
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            name: try c.decode(String.self, forKey: .name),
            points: try c.decode([Point].self, forKey: .points))
    }

    /// A constant: the same rpm at every temperature.
    public static func flat(name: String, rpm: Double) throws -> Curve {
        try Curve(name: name, points: [Point(c: 0, rpm: rpm)])
    }

    /// Linear interpolation between neighbours, flat beyond the ends.
    public func rpm(at celsius: Double) -> Double {
        if celsius <= points.first!.c { return points.first!.rpm }
        if celsius >= points.last!.c { return points.last!.rpm }
        let i = points.firstIndex { $0.c > celsius }!
        let (lo, hi) = (points[i - 1], points[i])
        let t = (celsius - lo.c) / (hi.c - lo.c)
        return lo.rpm + t * (hi.rpm - lo.rpm)
    }

    /// The rpm this curve asks of `fan` at `celsius`, inside its envelope.
    public func target(at celsius: Double, for fan: Fan) -> Double {
        fan.clamp(rpm(at: celsius))
    }
}

public enum CurveError: Error, CustomStringConvertible, Hashable {
    case unnamed
    case noPoints(String)
    case duplicateTemperature(String, Double)
    case negativeRPM(String, Double)

    public var description: String {
        switch self {
        case .unnamed: return "curve has no name"
        case .noPoints(let name): return "curve \"\(name)\" has no points"
        case .duplicateTemperature(let name, let c):
            return "curve \"\(name)\" has two points at \(c) C"
        case .negativeRPM(let name, let rpm):
            return "curve \"\(name)\" has a negative rpm (\(rpm))"
        }
    }
}
