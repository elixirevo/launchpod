// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Launchpod",
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "Launchpod", targets: ["Launchpod"])],
    dependencies: [.package(path: "../../tools/library/Integrations/MacAppDiagnosticsSentry"), .package(name: "MacAppEssentials", path: "../../tools/library"), .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .target(name: "LaunchpodCore", dependencies: ["CSQLite"]),
        .executableTarget(name: "Launchpod", dependencies: [
            "LaunchpodCore", .product(name: "Sparkle", package: "Sparkle"),
            .product(name: "MacAppCore", package: "MacAppEssentials"),
            .product(name: "MacAppSettings", package: "MacAppEssentials"),
            .product(name: "MacAppOnboarding", package: "MacAppEssentials"),
            .product(name: "MacAppDiagnosticsSentry", package: "MacAppDiagnosticsSentry")
        ], resources: [.copy("Resources/Legal"), .copy("Resources/Onboarding"), .copy("Resources/SentryConfiguration.json")], linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .executableTarget(name: "CoreChecks", dependencies: ["LaunchpodCore", "CSQLite"])
    ],
    swiftLanguageModes: [.v5]
)
