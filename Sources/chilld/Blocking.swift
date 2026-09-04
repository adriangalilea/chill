import Foundation

/// Run one async job to completion from a synchronous context that is
/// NOT the main thread: the top level before `dispatchMain`, a signal
/// source's handler, the power callback that must finish `auto` before it
/// acknowledges a sleep. The job's actor hops run on the cooperative pool
/// while the caller's thread waits on a semaphore.
func blocking(_ job: @escaping @Sendable () async throws -> Void) throws {
    let done = DispatchSemaphore(value: 0)
    let outcome = OutcomeBox()
    Task.detached {
        do { try await job() } catch { outcome.error = error }
        done.signal()
    }
    done.wait()
    if let error = outcome.error { throw error }
}

func blocking(_ job: @escaping @Sendable () async -> Void) {
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        await job()
        done.signal()
    }
    done.wait()
}

final class OutcomeBox: @unchecked Sendable {
    var error: Error?
}

/// A refusal at start: the daemon cannot do its job, so it says why on
/// both logs and exits 1. launchd records the exit; KeepAlive retries.
func refuse(_ error: Error) -> Never {
    Log.fault("\(error)")
    FileHandle.standardError.write(Data("chilld: \(error)\n".utf8))
    exit(1)
}
