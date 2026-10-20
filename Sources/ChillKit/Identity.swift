import Foundation

/// Which chill this process is: the release (`garden.untitled.chill`, Developer
/// ID, installed by its release or the cask) or a development build
/// (`garden.untitled.chill.dev`, "chill Dev", signed with the Apple
/// Development certificate by `mise run install`; an unbundled `swift build`
/// binary counts as development too). chilld answers with its app's identity
/// (its executable lives in the app's bundle). Two apps to macOS on purpose:
/// SMAppService pins a daemon to the certificate type that first registered
/// it (untitled docs/apple.md "Development builds"). A development build has
/// its own daemon (`garden.untitled.chilld.dev`: label, mach service, plist)
/// and its own roots: user state, the daemon's policy and its log.
public enum Identity {
    public static let release = "garden.untitled.chill"
    public static let bundleID = Bundle.main.bundleIdentifier ?? release + ".dev"
    public static let dev = bundleID != release
    /// The daemon's launchd label, mach service and plist name, one string.
    public static let daemon = dev ? "garden.untitled.chilld.dev" : "garden.untitled.chilld"
    /// A root's name for this build: the base, or its `-dev` sibling.
    public static func root(_ base: String) -> String { dev ? base + "-dev" : base }
}
