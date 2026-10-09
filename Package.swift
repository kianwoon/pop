// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Pop",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .executable(name: "Pop", targets: ["Pop"])
    ],
    targets: [
        .executableTarget(
            name: "Pop",
            path: "Sources/Pop",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                // WHY: DEV CONVENIENCE ONLY. macOS TCC aborts a privacy request
                // when the usage string is absent from the running artifact's
                // Info.plist, so the bare `swift build` binary gets this dev
                // plist baked into __TEXT,__info_plist. It must NOT ship in a
                // RELEASE build: a com.pop.dev plist embedded inside a signed
                // com.pop.app bundle contradicts TCC's identity resolution and
                // coincides with tccd aborting mic/speech requests. The dev
                // binary can never actually request permissions anyway
                // (SpeechListener's bundle-context guard), so this is debug-only.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Config/Info-dev.plist"
                ], .when(configuration: .debug))
            ]
        )
    ]
)
