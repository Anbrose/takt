// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TaktKit",
    defaultLocalization: "zh-Hans",
    // macOS is only here so `swift test` can run the logic tests on the host.
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "TaktUI", targets: ["TaktUI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-openapi-generator", from: "1.10.0"),
        .package(url: "https://github.com/apple/swift-openapi-runtime", from: "1.8.0"),
        .package(url: "https://github.com/apple/swift-openapi-urlsession", from: "1.1.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio", exact: "0.18.4", traits: ["Diarizer"]),
    ],
    targets: [
        // Rules the device needs for instant feedback (drag preview distance, km formatting).
        .target(name: "TaktCore"),
        // Client generated from packages/contract (openapi.json is written by `pnpm openapi`).
        .target(
            name: "TaktAPI",
            dependencies: [
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "OpenAPIURLSession", package: "swift-openapi-urlsession"),
            ],
            plugins: [.plugin(name: "OpenAPIGenerator", package: "swift-openapi-generator")]
        ),
        // On-device note taking: segmented recording, transcription, diarization, local store.
        .target(
            name: "TaktNotes",
            dependencies: ["TaktCore", "TaktAPI", .product(name: "FluidAudio", package: "FluidAudio")]
        ),
        .target(name: "TaktUI", dependencies: ["TaktCore", "TaktAPI", "TaktNotes"]),
        .testTarget(name: "TaktCoreTests", dependencies: ["TaktCore"]),
        .testTarget(name: "TaktAPITests", dependencies: ["TaktAPI"]),
        .testTarget(name: "TaktUITests", dependencies: ["TaktUI"]),
        .testTarget(
            name: "TaktNotesTests",
            dependencies: ["TaktNotes", "TaktCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
