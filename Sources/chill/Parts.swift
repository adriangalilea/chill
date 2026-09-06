import Foundation
import MachSensors

/// The chip's parts with a NAME: SMC temperature keys catalogued per
/// generation by exelban/stats (MIT, github.com/exelban/stats,
/// Modules/Sensors/values.swift at 0edcad84e0e9), the one maintained
/// index of Apple's otherwise unpublished keys; the tables below are
/// vendored from it and credited in README. The HID die sensors say
/// only `tdie<n>` from M3 on; these say cpu, gpu, memory. A key the
/// catalogue lists and this Mac lacks is dropped at open.
enum Parts {
    enum Group: String, CaseIterable {
        case cpu, gpu, memory
    }

    struct Reading {
        let group: Group
        let celsius: [Double]
    }

    /// The chip generation from the brand string, `Apple M5 Max` → 5.
    static var generation: Int? {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var bytes = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &bytes, &size, nil, 0)
        let brand = String(cString: bytes)
        guard let m = brand.range(of: #"Apple M(\d+)"#, options: .regularExpression) else {
            return nil
        }
        return Int(brand[m].dropFirst(7))
    }

    /// The catalogue: generation → group → keys.
    static func keys(generation: Int) -> [Group: [String]] {
        switch generation {
        case 3:
            return [
                .cpu: [
                    "Te05", "Te0L", "Te0P", "Te0S", "Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E",
                    "Tf44", "Tf49", "Tf4A", "Tf4B", "Tf4D", "Tf4E",
                ],
                .gpu: ["Tf14", "Tf18", "Tf19", "Tf1A", "Tf24", "Tf28", "Tf29", "Tf2A"],
            ]
        case 4:
            return [
                .cpu: [
                    "Te05", "Te0S", "Te09", "Te0H", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0V", "Tp0Y",
                    "Tp0b", "Tp0e",
                ],
                .gpu: ["Tg0K", "Tg0L", "Tg0d", "Tg0e", "Tg0j", "Tg0k"],
                .memory: ["Tm0p", "Tm1p", "Tm2p"],
            ]
        case 5:
            return [
                .cpu: [
                    "Tp00", "Tp04", "Tp08", "Tp0C", "Tp0G", "Tp0K", "Tp0O", "Tp0R", "Tp0U", "Tp0X",
                    "Tp0a", "Tp0d", "Tp0g", "Tp0j", "Tp0m", "Tp0p", "Tp0u", "Tp0y",
                ],
                .gpu: ["Tg0U", "Tg0X", "Tg0d", "Tg0g", "Tg0j", "Tg1Y", "Tg1c", "Tg1g"],
            ]
        default:
            return [:]
        }
    }

    /// The keys this Mac answers, probed once with READ_KEYINFO and kept
    /// only as 4-byte floats, the type every one of these reads as on
    /// Apple Silicon.
    static func present(_ smc: SMC) -> [Group: [String]] {
        guard let generation else {
            log.info("parts: no Apple M<n> in the brand string; no named parts")
            return [:]
        }
        var found: [Group: [String]] = [:]
        for (group, keys) in keys(generation: generation) {
            let live = keys.filter { key in
                guard let info = try? smc.info(key) else { return false }
                return info.type == "flt " && info.size == 4
            }
            if !live.isEmpty { found[group] = live }
            log.info(
                "parts: M\(generation) \(group.rawValue, privacy: .public): \(live.count, privacy: .public) of \(keys.count, privacy: .public) keys answer"
            )
        }
        return found
    }

    /// One reading per group, every key's value, invalid ones dropped.
    static func read(_ smc: SMC, _ present: [Group: [String]]) -> [Reading] {
        Group.allCases.compactMap { group in
            guard let keys = present[group] else { return nil }
            let values = keys.compactMap { key -> Double? in
                guard let v = try? smc.float(key), v > 10, v < 130 else { return nil }
                return Double(v)
            }
            return values.isEmpty ? nil : Reading(group: group, celsius: values)
        }
    }
}
