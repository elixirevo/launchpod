// swift-tools-version: 5.7
import PackageDescription

let package = Package(
    name: "Launchpod",
    platforms: [.macOS(.v12)],
    products: [.executable(name: "Launchpod", targets: ["Launchpod"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .target(name: "LaunchpodCore", dependencies: ["CSQLite"]),
        .executableTarget(name: "Launchpod", dependencies: [
            "LaunchpodCore", .product(name: "Sparkle", package: "Sparkle")
        ], linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .executableTarget(name: "CoreChecks", dependencies: ["LaunchpodCore", "CSQLite"])
    ]
)
