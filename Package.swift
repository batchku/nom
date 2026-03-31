// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Nom",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "NomApp", targets: ["NomApp"]),
        .executable(name: "nom", targets: ["NomCLI"]),
    ],
    targets: [
        .target(
            name: "NomCore",
            linkerSettings: [
                .unsafeFlags(["-F/System/Library/PrivateFrameworks", "-framework", "SkyLight"])
            ]
        ),
        .executableTarget(
            name: "NomApp",
            dependencies: ["NomCore"]
        ),
        .executableTarget(
            name: "NomCLI",
            dependencies: ["NomCore"]
        ),
    ]
)
