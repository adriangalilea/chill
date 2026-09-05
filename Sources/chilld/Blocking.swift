import Foundation

/// A refusal at start: the daemon cannot do its job, so it says why on
/// both logs and exits 1. launchd records the exit; KeepAlive retries.
func refuse(_ error: Error) -> Never {
    Log.fault("\(error)")
    FileHandle.standardError.write(Data("chilld: \(error)\n".utf8))
    exit(1)
}
