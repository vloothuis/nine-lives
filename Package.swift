// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NineLives",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "NineLives", targets: ["NineLivesApp"]),
    ],
    targets: [
        .target(name: "BorgKit"),
        .target(
            name: "NineLivesCore",
            dependencies: ["BorgKit"],
            linkerSettings: [
                .linkedFramework("DiskArbitration"),
                .linkedFramework("IOKit"),
                .linkedFramework("Security"),
            ]
        ),
        .executableTarget(name: "NineLivesApp", dependencies: ["NineLivesCore"]),
        .testTarget(name: "BorgKitTests", dependencies: ["BorgKit"]),
        .testTarget(name: "NineLivesCoreTests", dependencies: ["NineLivesCore", "BorgKit"]),
    ],
    swiftLanguageModes: [.v5]
)
