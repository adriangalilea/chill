// swift-tools-version: 6.2
// Three targets, one contract. ChillKit is the wire every process links:
// the protocol, the payloads and the curve model. chilld is the root
// daemon and the only SMC writer; it links Foundation, IOKit, ChillKit and
// the read-only sensor package, never AppKit, never swift-utils. chill is
// the app and the CLI in one binary, argv-dispatched.
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
        .package(url: "https://github.com/adriangalilea/swift-utils", from: "0.13.0"),
    ],
    targets: [
        .target(
            name: "ChillKit",
            swiftSettings: [.swiftLanguageMode(.v5), .enableUpcomingFeature("StrictConcurrency")]
        ),
        .executableTarget(
            name: "chilld",
            dependencies: [
                "ChillKit",
                .product(name: "MachSensors", package: "swift-hw"),
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
            ],
            swiftSettings: [.swiftLanguageMode(.v5), .enableUpcomingFeature("StrictConcurrency")]
        ),
    ]
)
