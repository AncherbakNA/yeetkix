// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Yeetkix",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Yeetkix", targets: ["Yeetkix"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")],
    targets: [
        .target(name: "LumaCore"),
        .executableTarget(name: "Yeetkix", dependencies: ["LumaCore", .product(name: "Sparkle", package: "Sparkle")], path: "Sources/Luma",
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .executableTarget(name: "LumaChecks", dependencies: ["LumaCore"], path: "Tests/LumaCoreTests")
    ]
)
