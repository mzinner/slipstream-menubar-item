// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "SlipstreamMenubar",
    platforms: [.macOS(.v15)],
    targets: [
        // Everything that can be tested without a running app: metrics parsing,
        // rates, status resolution, configuration and host sampling.
        .target(name: "SlipstreamMenubarCore"),
        .executableTarget(
            name: "SlipstreamMenubar",
            dependencies: ["SlipstreamMenubarCore"]
        ),
        .testTarget(
            name: "SlipstreamMenubarCoreTests",
            dependencies: ["SlipstreamMenubarCore"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
