import ChillKit

/// Apple's curve as the daemon observes it: one fan's (celsius, rpm)
/// samples while Apple holds it, binned 1 C x `Cloud.rpmBin` rpm. Lives
/// in memory for the daemon's life and is rendered into every `State`;
/// the app owns the file. Capped at `Cloud.maxBins` distinct bins: past
/// the cap, samples that would open a new bin are dropped and the cap is
/// logged once.
struct Histogram {
    private struct Bin: Hashable {
        let celsius: Int
        let rpm: Int
    }

    let fan: Int
    private var counts: [Bin: Int] = [:]
    private var saturated = false

    init(fan: Int) { self.fan = fan }

    mutating func add(celsius: Double, rpm: Double) {
        let bin = Bin(
            celsius: Int(celsius.rounded(.down)),
            rpm: Int(rpm / Double(Cloud.rpmBin)) * Cloud.rpmBin)
        if counts[bin] == nil && counts.count >= Cloud.maxBins {
            if !saturated {
                Log.notice("cloud: fan \(fan) at \(Cloud.maxBins) bins, new bins dropped")
                saturated = true
            }
            return
        }
        counts[bin, default: 0] += 1
    }

    /// The wire form: `[celsius, rpm, count]` triples, sorted for a
    /// stable document.
    func render() -> Cloud {
        Cloud(
            fan: fan,
            bins: counts.map { [$0.key.celsius, $0.key.rpm, $0.value] }
                .sorted { ($0[0], $0[1]) < ($1[0], $1[1]) })
    }
}
