// swift-tools-version: 6.4
// The replay that proves what a curve follows: a recorded trace through the
// curve as the raw die drives it and as `Heat.follow` drives it, the fans
// stepped by the demo daemon's physics, and what a person hears counted.
// Links chill's own ChillKit, so the function measured is the one shipped.
import PackageDescription

let package = Package(
    name: "HeatReplay",
    platforms: [.macOS(.v27)],
    dependencies: [.package(path: "../..")],
    targets: [
        .executableTarget(
            name: "heat-replay",
            dependencies: [.product(name: "ChillKit", package: "chill")],
            path: "Sources",
            swiftSettings: [.swiftLanguageMode(.v6), .defaultIsolation(MainActor.self)]
        )
    ]
)
