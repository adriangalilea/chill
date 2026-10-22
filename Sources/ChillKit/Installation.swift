import AppInstallations
import Foundation

extension AppInstallation.Job {
    /// chilld as the app's job, declared once for every chill process
    /// (swift-utils AppInstallations): a root daemon, so it runs only from
    /// an install for everyone (/Applications). Its witness is chilld itself
    /// answering a hello, stronger than launchd's word; before any
    /// unregister stops it (unregistering sends no SIGTERM), the fans go to
    /// Apple over XPC and nothing is forced until the stop, so no stop ever
    /// leaves a fan forced. The intent stays as the person set it: an
    /// upgrade's new chilld takes their curve back. Both calls are bounded by
    /// the client's reply watchdog, and a chilld that is not loaded fails
    /// them at once.
    public static let chilld = AppInstallation.Job(
        .daemon(plist: Wire.plistName), name: "chilld",
        answers: {
            (try? blocking { try await Client(demo: Demo(on: false), role: .cli).hello() }) != nil
        },
        handBack: {
            _ = try? blocking { try await Client(demo: Demo(on: false), role: .cli).handBack() }
        })
}
