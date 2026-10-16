// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "macmpv",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "macmpv", targets: ["macmpv"])
    ],
    dependencies: [
        // Software updates, verified with an EdDSA key independent of GitHub.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        .systemLibrary(
            name: "CMPV",
            path: "Sources/CMPV",
            pkgConfig: "mpv",
            providers: [
                .brew(["mpv"])
            ]
        ),
        .executableTarget(
            name: "macmpv",
            dependencies: [
                "CMPV",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/Cinewave",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("OpenGL"),
                .linkedFramework("QuartzCore")
            ]
        ),
        .testTarget(
            name: "macmpvTests",
            dependencies: ["macmpv"],
            resources: [.copy("Fixtures")]
        )
    ]
)
