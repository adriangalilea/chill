import ChillKit
import Foundation
import MachSensors

/// Why the writer refused; each one is a log line and, at daemon start,
/// the exit message.
enum WriterError: Error, CustomStringConvertible {
    /// A fan rpm key is `fpe2`: an Intel Mac. chill is Apple Silicon only.
    case intel(key: String)
    /// The reported envelope is not positive and ordered.
    case envelope(fan: Int, min: Double, max: Double)
    /// Mode 1 did not hold within `SMCWriter.acquireTimeout`.
    case acquireTimedOut(fan: Int, mode: UInt8)
    /// Mode never read 0 or 3 within `SMCWriter.releaseTimeout`.
    case releaseTimedOut(fan: Int, mode: UInt8)
    /// `reconcile` ran `auto` on EVERY fan and these refused; the others
    /// are Apple's.
    case reconcile([(fan: Int, error: Error)])

    var description: String {
        switch self {
        case .intel(let key):
            return "smc: \(key) is fpe2, an Intel Mac; chill drives Apple Silicon fans only"
        case .envelope(let fan, let min, let max):
            return "smc: fan \(fan) reports envelope \(min)..\(max) rpm, not positive and ordered"
        case .acquireTimedOut(let fan, let mode):
            return "smc: fan \(fan) would not leave mode \(mode) for mode 1"
        case .releaseTimedOut(let fan, let mode):
            return "smc: fan \(fan) still reads mode \(mode) after auto"
        case .reconcile(let failures):
            return "smc: reconcile: "
                + failures.map { "fan \($0.fan): \($0.error)" }.joined(separator: "; ")
        }
    }
}

/// The ONLY SMC writer. One IOKit connection for the daemon's life, the
/// envelope read once and cached, the mode key spelled as this machine
/// spells it, `Ftst` probed once. Every write is composed as cmd 6 on
/// MachSensors' codec after a READ_KEYINFO type assertion, and every reply's
/// result byte is judged by `SMC.call` (0x84 no key, 0x82 rejected);
/// KERN_SUCCESS alone means nothing.
///
/// An actor so the connection is never called from two threads: the
/// acquire loop sleeps between retries and the evaluator's target writes
/// interleave with it instead of waiting behind it.
actor SMCWriter {
    /// Targets closer than this to the current target are not written.
    static let hysteresis: Double = 50
    /// The most a target moves per 1 Hz sample toward the curve value; the
    /// physical ramp is the firmware's.
    static let slewPerSample: Double = 300
    static let acquireTimeout: Duration = .seconds(10)
    static let acquireRetry: Duration = .milliseconds(100)
    static let releaseTimeout: Duration = .seconds(10)
    static let releasePoll: Duration = .milliseconds(100)

    /// The envelope thermalmonitord reports, read once: what `hello` ships
    /// and every target clamps to. Empty on a fanless Mac.
    nonisolated let fans: [Fan]
    /// Whether the `Ftst` force-test key exists (absent on M5).
    nonisolated let hasFtst: Bool

    private let smc: SMC
    private let modeKeys: [String]
    private var acquiring: [Int: (ticket: Int, task: Task<Void, Never>)] = [:]
    private var ticket = 0

    init() throws {
        let smc = try SMC()
        let count = Int(try smc.uint8("FNum"))
        var fans: [Fan] = []
        var modeKeys: [String] = []
        for n in 0..<count {
            // The first rpm key touched per fan goes through `expect`, so
            // an Intel `fpe2` surfaces as `WriterError.intel`, not as a
            // type mismatch on the envelope read.
            try SMCWriter.expect(smc, "F\(n)Tg", is: "flt ", size: 4)
            let min = Double(try smc.float("F\(n)Mn"))
            let max = Double(try smc.float("F\(n)Mx"))
            guard min > 0, min < max else { throw WriterError.envelope(fan: n, min: min, max: max) }
            fans.append(Fan(index: n, min: min, max: max))
            let modeKey = try smc.modeKey(fan: n)
            try SMCWriter.expect(smc, modeKey, is: "ui8 ", size: 1)
            modeKeys.append(modeKey)
        }
        let hasFtst: Bool
        do {
            try SMCWriter.expect(smc, "Ftst", is: "ui8 ", size: 1)
            hasFtst = true
        } catch SMCError.noKey {
            hasFtst = false
        }
        self.smc = smc
        self.fans = fans
        self.modeKeys = modeKeys
        self.hasFtst = hasFtst
        Log.notice(
            "smc: \(count) fans, "
                + fans.map { "fan \($0.index) \(Int($0.min))..\(Int($0.max)) rpm" }.joined(
                    separator: ", ")
                + (count > 0
                    ? ", mode key \(modeKeys[0]), Ftst \(hasFtst ? "present" : "absent")" : ""))
    }

    // MARK: - reads

    /// One fan as the SMC reads it right now.
    func read(fan n: Int) throws -> FanState {
        FanState(
            index: n,
            actual: Double(try smc.float("F\(n)Ac")),
            target: Double(try smc.float("F\(n)Tg")),
            mode: try smc.uint8(modeKeys[n]))
    }

    func mode(fan n: Int) throws -> UInt8 { try smc.uint8(modeKeys[n]) }

    /// `Ftst` as it reads, nil where the key does not exist.
    func ftst() throws -> UInt8? { hasFtst ? try smc.uint8("Ftst") : nil }

    func isAcquiring(fan n: Int) -> Bool { acquiring[n] != nil }

    // MARK: - acquire

    /// Take fan `n` on its own task; a second call while one is in flight
    /// is a no-op. The fan reads `acquiring` until the read-back is 1.
    func beginAcquire(fan n: Int) {
        guard acquiring[n] == nil else { return }
        ticket += 1
        let mine = ticket
        let task = Task {
            do {
                try await self.acquire(fan: n)
            } catch is CancellationError {
                Log.notice("fan \(n): acquire cancelled")
            } catch {
                Log.error("fan \(n): acquire failed: \(error)")
            }
            if self.acquiring[n]?.ticket == mine { self.acquiring[n] = nil }
        }
        acquiring[n] = (mine, task)
    }

    /// Write mode 1 and read it back. If it did not stick and `Ftst`
    /// exists: `Ftst = 1`, then mode 1 every 100 ms for up to 10 s. `Ftst`
    /// stays 1 for the session so later target writes are single calls;
    /// `auto` clears it. Cancellation (only `auto` cancels) is honoured
    /// before every mode write, so a cancelled acquire never re-forces a
    /// fan `auto` is releasing; `auto` then owns `Ftst`. Any other failure
    /// after the `Ftst = 1` write clears it on the way out: a raised `Ftst`
    /// with no session behind it mutes Apple's servo.
    func acquire(fan n: Int) async throws {
        try Task.checkCancellation()
        let key = modeKeys[n]
        let before = try smc.uint8(key)
        if try force(key) == 1 {
            Log.notice("fan \(n): acquired, mode \(before) -> 1")
            return
        }
        guard hasFtst else {
            let stuck = try smc.uint8(key)
            throw WriterError.acquireTimedOut(fan: n, mode: stuck)
        }
        try write("Ftst", uint8: 1)
        Log.notice("fan \(n): mode 1 did not hold, Ftst 1, retrying")
        do {
            let clock = ContinuousClock()
            let started = clock.now
            while clock.now - started < SMCWriter.acquireTimeout {
                try await Task.sleep(for: SMCWriter.acquireRetry)
                try Task.checkCancellation()
                if try force(key) == 1 {
                    let took = (clock.now - started).seconds
                    Log.notice("fan \(n): acquired, mode \(before) -> 1 after \(took) s with Ftst")
                    return
                }
            }
            let stuck = try smc.uint8(key)
            throw WriterError.acquireTimedOut(fan: n, mode: stuck)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            do {
                try write("Ftst", uint8: 0)
                Log.notice("fan \(n): Ftst 1 -> 0 after a failed acquire")
            } catch let clearing {
                Log.error("fan \(n): Ftst 1 -> 0 after a failed acquire: \(clearing)")
            }
            throw error
        }
    }

    /// Mode 1 written, mode read back. A 0x82 is "did not stick", not an
    /// error: thermalmonitord holding mode 3 answers that way.
    private func force(_ modeKey: String) throws -> UInt8 {
        do {
            try write(modeKey, uint8: 1)
        } catch SMCError.rejected(_, 0x82) {}
        return try smc.uint8(modeKey)
    }

    // MARK: - auto

    /// Hand fan `n` back to Apple: cancel an acquire in flight, mode 0,
    /// `Ftst = 0` if it reads 1, then poll the mode until it reads 0 or 3.
    /// A fan Apple already holds with `Ftst` clear is left alone: writing 0
    /// over mode 3 invites a 0x82 and a servo blip for nothing.
    func auto(fan n: Int) async throws {
        if let inFlight = acquiring[n] {
            inFlight.task.cancel()
            acquiring[n] = nil
        }
        let key = modeKeys[n]
        let before = try smc.uint8(key)
        let ftstBefore = try ftst()
        let appleHolds = before == 0 || before == 3
        if appleHolds && ftstBefore != 1 {
            Log.notice("fan \(n): apple holds it, mode \(before)")
            return
        }
        if !appleHolds { try write(key, uint8: 0) }
        if ftstBefore == 1 { try write("Ftst", uint8: 0) }
        let clock = ContinuousClock()
        let started = clock.now
        var mode = try smc.uint8(key)
        while mode != 0 && mode != 3 {
            guard clock.now - started < SMCWriter.releaseTimeout else {
                throw WriterError.releaseTimedOut(fan: n, mode: mode)
            }
            try await Task.sleep(for: SMCWriter.releasePoll)
            mode = try smc.uint8(key)
        }
        let took = (clock.now - started).seconds
        Log.notice(
            "fan \(n): auto, mode \(before) -> \(mode) after \(took) s"
                + (ftstBefore == 1 ? ", Ftst 1 -> 0" : ""))
    }

    /// The daemon's first act and every exit path's last: `auto` on EVERY
    /// fan, one that refuses never shielding the next, then the read-back
    /// logged for all. Throws `reconcile` naming the fans that refused.
    func reconcile() async throws {
        guard !fans.isEmpty else {
            Log.notice("this Mac has no fans")
            return
        }
        var failures: [(fan: Int, error: Error)] = []
        for fan in fans {
            do {
                try await auto(fan: fan.index)
            } catch {
                failures.append((fan.index, error))
            }
        }
        Log.notice(
            "reconciled: "
                + fans.map { fan in
                    do {
                        let state = try read(fan: fan.index)
                        return "fan \(fan.index) mode \(state.mode) target \(Int(state.target))"
                    } catch {
                        return "fan \(fan.index) unreadable (\(error))"
                    }
                }.joined(separator: ", "))
        if !failures.isEmpty { throw WriterError.reconcile(failures) }
    }

    // MARK: - target

    /// Move fan `n`'s target toward `rpm`: clamped to the cached envelope,
    /// unchanged within the hysteresis, at most `slewPerSample` per call.
    /// The current target is READ from `F{n}Tg`, never remembered, so the
    /// first step after acquire starts from what Apple last asked.
    /// Returns the target the fan holds after the call.
    @discardableResult
    func target(fan n: Int, rpm: Double) throws -> Double {
        let wanted = fans[n].clamp(rpm)
        let current = Double(try smc.float("F\(n)Tg"))
        let delta = wanted - current
        guard abs(delta) > SMCWriter.hysteresis else { return current }
        let step = Swift.max(-SMCWriter.slewPerSample, Swift.min(SMCWriter.slewPerSample, delta))
        let next = fans[n].clamp(current + step)
        try write("F\(n)Tg", float: Float(next))
        Log.notice("fan \(n): target \(Int(current)) -> \(Int(next)) (curve \(Int(wanted)))")
        return next
    }

    // MARK: - the write path

    private func write(_ key: String, uint8 value: UInt8) throws {
        try SMCWriter.expect(smc, key, is: "ui8 ", size: 1)
        _ = try smc.call(SMCMessage(key: key, command: .writeBytes, dataSize: 1, payload: [value]))
    }

    private func write(_ key: String, float value: Float) throws {
        try SMCWriter.expect(smc, key, is: "flt ", size: 4)
        let bits = value.bitPattern
        let bytes = (0..<4).map { UInt8(truncatingIfNeeded: bits >> (8 * $0)) }
        _ = try smc.call(SMCMessage(key: key, command: .writeBytes, dataSize: 4, payload: bytes))
    }

    /// READ_KEYINFO before a write: the key's type and size must be what
    /// the payload encodes. `fpe2` names an Intel Mac by its own error.
    private static func expect(_ smc: SMC, _ key: String, is type: String, size: Int) throws {
        let info = try smc.info(key)
        if info.type == "fpe2" { throw WriterError.intel(key: key) }
        guard info.type == type, info.size == size else {
            throw SMCError.unexpectedType(
                key: key, got: "\(info.type)/\(info.size)", want: "\(type)/\(size)")
        }
    }
}
