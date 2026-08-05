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
            dependencies: ["CMPV"],
            path: "Sources/Cinewave",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("OpenGL")
            ]
        )
    ]
)
