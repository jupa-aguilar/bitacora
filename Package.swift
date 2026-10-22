// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Bitacora",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "bitacora", targets: ["bitacora"]),
        .library(name: "BitacoraCore", targets: ["BitacoraCore"]),
    ],
    targets: [
        .target(
            name: "BitacoraCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "bitacora",
            dependencies: ["BitacoraCore"]
        ),
        .testTarget(
            name: "BitacoraCoreTests",
            dependencies: ["BitacoraCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
