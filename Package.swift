// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NineLives",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "NineLives", targets: ["NineLivesApp"]),
    ],
    targets: [
        .target(name: "ResticKit"),
        .target(
            name: "NineLivesCore",
            dependencies: ["ResticKit"],
            linkerSettings: [
                .linkedFramework("DiskArbitration"),
                .linkedFramework("IOKit"),
                .linkedFramework("Security"),
            ]
        ),
        .executableTarget(name: "NineLivesApp", dependencies: ["NineLivesCore"]),
        .testTarget(name: "ResticKitTests", dependencies: ["ResticKit"]),
        .testTarget(name: "NineLivesCoreTests", dependencies: ["NineLivesCore", "ResticKit"]),
    ],
    swiftLanguageModes: [.v5]
)
