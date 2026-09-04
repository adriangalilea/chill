import ChillKit
import Foundation

/// One cell of the reference histogram: 1 °C by `Cloud.rpmBin` rpm.
struct Bin: Hashable {
    let c: Int
    let rpm: Int
}

/// `~/.local/state/chill/cloud/<fan>.json`: Apple's behaviour as this
/// Mac has shown it, across daemon restarts and reboots. The daemon ships
/// only what it accumulated since ITS start (`State.clouds`, in memory,
/// never written by root into a home directory); the app folds each
/// shipment in as a DELTA against what it already absorbed from that
/// daemon instance (`seen`, keyed by the daemon's pid), so a restart
/// starts a fresh delta and a relaunched app never counts a sample twice.
/// Written on quit and every five minutes; counts halved monthly so the
/// cloud follows the machine's present, capped at `Cloud.maxBins` by
/// dropping the thinnest bins.
@MainActor
final class CloudStore {
    static let halvingPeriod: TimeInterval = 30 * 24 * 3600
    static let writePeriod: TimeInterval = 5 * 60

    private struct File: Codable {
        struct Seen: Codable {
            let pid: Int32
            let bins: [[Int]]
        }
        let fan: Int
        let bins: [[Int]]
        let seen: Seen?
        let lastHalved: Date
    }

    let directory: URL
    /// Everything absorbed, per fan: what the canvas draws.
    private(set) var bins: [Int: [Bin: Int]] = [:]
    private var seen: [Int: (pid: Int32, bins: [Bin: Int])] = [:]
    private var lastHalved: [Int: Date] = [:]

    /// Reads every `<fan>.json`; the demo root is seeded with the
    /// scripted cloud when it does not exist yet.
    init(demo: Demo) throws {
        directory = demo.cloud
        if !FileManager.default.fileExists(atPath: directory.path) {
            guard demo.on else { return }
            for fan in FakeDaemon.fans {
                bins[fan.index] = CloudStore.table(Demo.seedCloud(fan).bins)
                lastHalved[fan.index] = .now
            }
            try write()
            return
        }
        let files = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }
        for url in files {
            let file = try Wire.decode(File.self, from: Data(contentsOf: url))
            bins[file.fan] = CloudStore.table(file.bins)
            lastHalved[file.fan] = file.lastHalved
            if let s = file.seen { seen[file.fan] = (s.pid, CloudStore.table(s.bins)) }
        }
    }

    /// Fold a daemon's shipment in: only the growth since the last
    /// shipment from the same pid counts.
    func absorb(_ clouds: [Cloud], from pid: Int32) {
        for cloud in clouds {
            let fresh = CloudStore.table(cloud.bins)
            let before = seen[cloud.fan]?.pid == pid ? seen[cloud.fan]!.bins : [:]
            var mine = bins[cloud.fan] ?? [:]
            for (bin, count) in fresh {
                let delta = count - (before[bin] ?? 0)
                if delta > 0 { mine[bin, default: 0] += delta }
            }
            bins[cloud.fan] = mine
            seen[cloud.fan] = (pid, fresh)
            if lastHalved[cloud.fan] == nil { lastHalved[cloud.fan] = .now }
        }
    }

    /// One file per fan, the monthly halving applied first. Nothing
    /// absorbed yet = nothing on disk, not even the directory.
    func write() throws {
        guard !bins.isEmpty else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for fan in bins.keys.sorted() {
            var table = bins[fan]!
            let halved = lastHalved[fan] ?? .now
            if Date.now.timeIntervalSince(halved) >= CloudStore.halvingPeriod {
                table = table.mapValues { $0 / 2 }.filter { $0.value > 0 }
                lastHalved[fan] = .now
            }
            if table.count > Cloud.maxBins {
                let kept = table.sorted { $0.value > $1.value }.prefix(Cloud.maxBins)
                table = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
            }
            bins[fan] = table
            let file = File(
                fan: fan, bins: CloudStore.triples(table),
                seen: seen[fan].map { File.Seen(pid: $0.pid, bins: CloudStore.triples($0.bins)) },
                lastHalved: lastHalved[fan]!)
            try Wire.encode(file, pretty: true).write(
                to: directory.appending(path: "\(fan).json"), options: .atomic)
        }
    }

    private static func table(_ triples: [[Int]]) -> [Bin: Int] {
        var table: [Bin: Int] = [:]
        for triple in triples {
            precondition(triple.count == 3, "cloud bin \(triple) is not [c, rpm, count]")
            table[Bin(c: triple[0], rpm: triple[1])] = triple[2]
        }
        return table
    }

    private static func triples(_ table: [Bin: Int]) -> [[Int]] {
        table.map { [$0.key.c, $0.key.rpm, $0.value] }.sorted { ($0[0], $0[1]) < ($1[0], $1[1]) }
    }
}
