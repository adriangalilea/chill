// swift-tools-version: 6.2
// Three targets, one contract. ChillKit is the wire every process links:
// the protocol, the payloads, the curve model and chilld's declaration as
// the app's job. chilld is the root daemon and the only SMC writer; it
// links Foundation, IOKit, ChillKit and the read-only sensor package, and
// of swift-utils only AppInstallations (and its Log), which are
// Foundation-only: never AppKit. chill is the app and the CLI in one
// binary, argv-dispatched.
import PackageDescription

let package = Package(
    name: "chill",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "ChillKit", targets: ["ChillKit"])
    ],
    dependencies: [
        // MachSensors: die temperatures and SMC fan telemetry, read-only by
        // construction; chilld composes its write on the public codec.
        .package(url: "https://github.com/adriangalilea/swift-hw", from: "0.1.0"),
        // Ink + Keymap: the studio's look and the keyboard-first spine.
        // AppInstallations: the app's whole life (chilld as its job, the
        // move into Applications, upgrade and delete), in every process.
        .package(url: "https://github.com/adriangalilea/swift-utils", .upToNextMinor(from: "0.38.6")),
    ],
    targets: [
        .target(
            name: "ChillKit",
            dependencies: [.product(name: "AppInstallations", package: "swift-utils")],
            swiftSettings: [.swiftLanguageMode(.v5), .enableUpcomingFeature("StrictConcurrency")]
        ),
        .executableTarget(
            name: "chilld",
            dependencies: [
                "ChillKit",
                .product(name: "MachSensors", package: "swift-hw"),
                .product(name: "AppInstallations", package: "swift-utils"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5), .enableUpcomingFeature("StrictConcurrency")],
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .executableTarget(
            name: "chill",
            dependencies: [
                "ChillKit",
                .product(name: "MachSensors", package: "swift-hw"),
                .product(name: "Ink", package: "swift-utils"),
                .product(name: "Keymap", package: "swift-utils"),
                .product(name: "AppInstallations", package: "swift-utils"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5), .enableUpcomingFeature("StrictConcurrency")]
        ),
    ]
)
