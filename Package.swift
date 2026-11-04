// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LayerLens",
    platforms: [.iOS(.v15)],
    products: [
        // Xcode links this product as LayerLens.o; Release consumers can exclude it.
        .library(name: "LayerLens", targets: ["LayerLens"])
    ],
    targets: [
        .target(
            name: "LayerLens",
            path: ".",
            exclude: [
                "Mac", "Example", "Web", "docs",
                "AGENTS.md", "README.md", "README.zh-CN.md",
                "LICENSE", "LayerLens.podspec", "Pod/Classes/Vendor/Lookin/LICENSE"
            ],
            sources: ["Pod/Classes"],
            publicHeadersPath: "SPM/include",
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
