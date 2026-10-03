import ChillKit
import Foundation

/// Where this bundle stands, read from the bundle itself, because
/// `SMAppService.Status.notFound` alone says nothing usable: macOS answers
/// it for a bundle with no LaunchDaemons plist, for one running from the
/// dmg or translocated (a quarantined app opened where it was downloaded),
/// and for a daemon that was simply never registered. Each needs a
/// different act, so the registration is judged against this.
enum Placement: Equatable {
    /// The bundle carries chilld and lives in /Applications: registering is
    /// the act, and its error, if any, is the truth.
    case installable
    /// Running from anywhere else; a registration is bound to the bundle's
    /// path and launchd boots the daemon before any home exists, so the app
    /// belongs in /Applications (README › Install).
    case misplaced(path: String)
    /// No `Contents/Library/LaunchDaemons/<plist>`: a `swift build` binary
    /// or an unassembled bundle, which no registration can fix.
    case bare

    static var current: Placement {
        // From the executable with its links resolved, not `Bundle.main`: the
        // CLI also runs as ~/.local/bin/chill, a link into the bundle.
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else {
            return .bare
        }
        // Contents/MacOS/chill → the .app
        let bundle = executable.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let plist = bundle.appending(path: "Contents/Library/LaunchDaemons/\(Wire.plistName)")
        guard bundle.pathExtension == "app",
            FileManager.default.fileExists(atPath: plist.path)
        else { return .bare }
        guard bundle.deletingLastPathComponent().path == "/Applications" else {
            return .misplaced(path: bundle.path)
        }
        return .installable
    }

    /// What a `.notFound` registration means here, in the words every
    /// surface shows.
    var notFound: String {
        switch self {
        case .installable: return "not installed"
        case .misplaced(let path):
            let from =
                path.hasPrefix("/Volumes/")
                ? "the disk image"
                : path.contains("/AppTranslocation/")
                    ? "a copy macOS made of the download" : path
            return "chill is running from \(from): move it to Applications and open it there"
        case .bare: return "no chilld in this bundle (a bare build): mise run install"
        }
    }
}
