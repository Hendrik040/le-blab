// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LeBlab",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "LeBlab", targets: ["LeBlab"]),
        .executable(name: "leblab-probe", targets: ["leblab-probe"]),
        .library(name: "LeBlabCore", targets: ["LeBlabCore"]),
    ],
    targets: [
        .target(
            name: "LeBlabCore",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("Security"),
            ]
        ),
        .executableTarget(
            name: "LeBlab",
            dependencies: ["LeBlabCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "leblab-probe",
            dependencies: ["LeBlabCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "LeBlabCoreTests",
            dependencies: ["LeBlabCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
