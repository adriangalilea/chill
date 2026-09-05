import Foundation

/// Run one async job to completion from a synchronous thread that is not
/// serving the job's replies: the CLI's main thread (XPC replies land on
/// the connection's own queue), chilld's top level before `dispatchMain`,
/// a signal source's handler, the power callback that must finish `auto`
/// before it acknowledges a sleep. The job's actor hops run on the
/// cooperative pool while the caller's thread waits on a semaphore. The
/// error type follows the job: `blocking { await x() }` needs no `try`.
public func blocking<T: Sendable, E: Error>(_ job: @escaping @Sendable () async throws(E) -> T)
    throws(E) -> T
{
    let done = DispatchSemaphore(value: 0)
    let box = Box<T, E>()
    Task.detached {
        do throws(E) {
            box.outcome = .success(try await job())
        } catch {
            box.outcome = .failure(error)
        }
        done.signal()
    }
    done.wait()
    return try box.outcome!.get()
}

/// Written once by the detached task, read once after the semaphore: the
/// semaphore is the happens-before edge.
private final class Box<T, E: Error>: @unchecked Sendable {
    var outcome: Result<T, E>?
}
