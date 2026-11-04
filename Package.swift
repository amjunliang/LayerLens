// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LayerLens",
    platforms: [.iOS(.v15)],
    products: [
        // Exclude LayerLens.o and LayerLensCore.o in shipping Xcode configurations.
        .library(name: "LayerLens", targets: ["LayerLens"])
    ],
    targets: [
        .target(
            name: "LayerLens",
            dependencies: [
                .target(name: "LayerLensCore", condition: .when(platforms: [.iOS, .macCatalyst]))
            ],
            path: "SPM",
            exclude: ["CoreInclude"],
            sources: ["Entry"],
            publicHeadersPath: "include"
        ),
        .target(
            name: "LayerLensCore",
            path: ".",
            exclude: [
                "Mac", "Example", "Web", "docs",
                "AGENTS.md", "README.md", "README.zh-CN.md",
                "LICENSE", "LayerLens.podspec", "Pod/Classes/Vendor/Lookin/LICENSE"
            ],
            sources: ["Pod/Classes"],
            publicHeadersPath: "SPM/CoreInclude",
            cSettings: [
                .define("DEBUG", to: "1", .when(configuration: .debug)),
                .headerSearchPath("Pod/Classes"),
                .headerSearchPath("Pod/Classes/API"),
                .headerSearchPath("Pod/Classes/Log"),
                .headerSearchPath("Pod/Classes/Lookin"),
                .headerSearchPath("Pod/Classes/Network"),
                .headerSearchPath("Pod/Classes/Runtime"),
                .headerSearchPath("Pod/Classes/Sandbox"),
                .headerSearchPath("Pod/Classes/Server"),
                .headerSearchPath("Pod/Classes/Storage"),
                .headerSearchPath("Pod/Classes/Vendor/Lookin")
            ],
            linkerSettings: [
                .linkedFramework("UIKit"),
                .linkedFramework("Network"),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedLibrary("z"),
                .linkedLibrary("sqlite3")
            ]
        )
    ]
)
