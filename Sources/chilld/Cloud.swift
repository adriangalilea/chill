import ChillKit
import Foundation

/// Apple's curve as this Mac shows it: every (heat, rpm) sample taken while
/// Apple held a fan (mode 0 or 3), binned 1 °C by `rpmBin` rpm, per fan.
/// The daemon is the one process that samples it, so it is the one that
/// keeps it: `/Library/Application Support/chill/cloud.json`, read at start,
/// written every `writePeriod` and on every way out (a crash loses at most
/// that much), its counts halved every `halvingPeriod` so it follows the
/// machine's present, capped at `maxBins` per fan (past the cap a sample
/// that would open a new bin is dropped, said once). Recorded, never sent:
/// nothing draws it yet (README, TODO.md: Apple's observed curve as one
/// dotted line), and a record that grows has no place in a 1 Hz exchange.
struct Clouds {
    static let file = Policy.directory.appendingPathComponent("cloud.json")
    static let rpmBin = 50
    static let maxBins = 5000
    static let writePeriod: Duration = .seconds(5 * 60)
    static let halvingPeriod: TimeInterval = 30 * 24 * 3600

    private struct Bin: Hashable {
        let celsius: Int
        let rpm: Int
    }

    /// The file: `{ lastHalved, fans: [{ fan, bins: [[celsius, rpm, count]] }] }`,
    /// celsius and rpm the bin floors, sorted for a stable document.
    private struct Document: Codable {
        struct Fan: Codable {
            let fan: Int
            let bins: [[Int]]
        }
        let lastHalved: Date
        let fans: [Fan]
    }

    private var counts: [Int: [Bin: Int]]
    private var lastHalved: Date
    private var saturated: Set<Int> = []

    /// What the file holds, or nothing for a first start. A file that does
    /// not parse is said and set aside: a reference record is never worth
    /// refusing to run for, and the next write replaces it.
    static func load(fans: [Fan]) -> Clouds {
        let empty = Clouds(
            counts: Dictionary(uniqueKeysWithValues: fans.map { ($0.index, [:]) }),
            lastHalved: .now)
        guard FileManager.default.fileExists(atPath: file.path) else { return empty }
        do {
            let document = try Wire.decode(Document.self, from: Data(contentsOf: file))
            var counts = empty.counts
            for fan in document.fans where counts[fan.fan] != nil {
                for triple in fan.bins {
                    precondition(
                        triple.count == 3, "cloud bin \(triple) is not [celsius, rpm, count]")
                    counts[fan.fan]![Bin(celsius: triple[0], rpm: triple[1])] = triple[2]
                }
            }
            let total = counts.values.map(\.count).reduce(0, +)
            Log.notice("cloud: \(total) bins from \(file.path)")
            return Clouds(counts: counts, lastHalved: document.lastHalved)
        } catch {
            Log.error("cloud: \(file.path) does not parse (\(error)); starting a fresh one")
            return empty
        }
    }

    mutating func add(fan: Int, celsius: Double, rpm: Double) {
        let bin = Bin(
            celsius: Int(celsius.rounded(.down)), rpm: Int(rpm) / Clouds.rpmBin * Clouds.rpmBin)
        guard counts[fan] != nil else { preconditionFailure("cloud: no fan \(fan)") }
        if counts[fan]![bin] == nil && counts[fan]!.count >= Clouds.maxBins {
            if saturated.insert(fan).inserted {
                Log.notice("cloud: fan \(fan) at \(Clouds.maxBins) bins, new bins dropped")
            }
            return
        }
        counts[fan]![bin, default: 0] += 1
    }

    /// Halved first when a period has passed, then written atomically.
    mutating func save() {
        if Date.now.timeIntervalSince(lastHalved) >= Clouds.halvingPeriod {
            counts = counts.mapValues { $0.mapValues { $0 / 2 }.filter { $0.value > 0 } }
            lastHalved = .now
            saturated = []
            Log.notice("cloud: counts halved")
        }
        let document = Document(
            lastHalved: lastHalved,
            fans: counts.keys.sorted().map { fan in
                Document.Fan(
                    fan: fan,
                    bins: counts[fan]!.map { [$0.key.celsius, $0.key.rpm, $0.value] }
                        .sorted { ($0[0], $0[1]) < ($1[0], $1[1]) })
            })
        do {
            try FileManager.default.createDirectory(
                at: Policy.directory, withIntermediateDirectories: true)
            try Wire.encode(document).write(to: Clouds.file, options: .atomic)
        } catch {
            Log.error("cloud: cannot write \(Clouds.file.path): \(error)")
        }
    }
}
