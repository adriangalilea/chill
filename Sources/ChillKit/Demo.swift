import Foundation

/// The demo world (`--demo`, the studio decree): every content-bearing
/// root forks to a `-demo` sibling, so a showcase or a screen share can
/// never show, index or write real curves; the daemon is `FakeDaemon`,
/// in-process, never chilld; and every surface says which world it is on
/// screen (the CLI marks its headers, the window wears a `demo` kicker).
/// A value, threaded from argv to every verb, so nothing reads argv twice.
public struct Demo: Sendable, Equatable {
    public let on: Bool

    public init(on: Bool) { self.on = on }

    /// A root's name in this world: the base, or its `-demo` sibling.
    public func name(_ base: String) -> String { on ? base + "-demo" : base }

    /// A header in this world: "curves" → "curves · demo".
    public func mark(_ header: String) -> String { on ? header + " · demo" : header }

    /// `~/.local/state/chill` (curves, config, cloud), or its demo sibling.
    public var state: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".local/state/\(name("chill"))")
    }

    public var curves: URL { state.appending(path: "curves") }

    /// The curves a demo starts with, so `curve list` has something to
    /// list and `curve use` something to use.
    public static let seedCurves: [Curve] = [
        try! Curve(
            name: "quiet",
            points: [.init(c: 60, rpm: 2400), .init(c: 80, rpm: 3800), .init(c: 95, rpm: 6500)]),
        try! Curve(
            name: "cool",
            points: [.init(c: 45, rpm: 3000), .init(c: 70, rpm: 5500), .init(c: 85, rpm: 7826)]),
    ]
}
