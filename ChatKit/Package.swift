// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ChatKit",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v17),
    ],
    products: [
        .library(
            name: "ChatClient",
            targets: ["ChatClient"]
        ),
        .library(
            name: "ChatUI",
            // Keep ChatUI static to avoid missing runtime embed on device builds.
            targets: ["ChatUI"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/Lakr233/ListViewKit", from: "1.1.8"),
        .package(url: "https://github.com/Lakr233/MarkdownView", from: "3.7.0"),
        .package(url: "https://github.com/Lakr233/Litext", from: "1.2.1"),
        .package(url: "https://github.com/SnapKit/SnapKit.git", from: "5.7.1"),
        .package(url: "https://github.com/mischa-hildebrand/AlignedCollectionViewFlowLayout", from: "1.1.3"),
        .package(url: "https://github.com/ktiays/GlyphixTextFx/", from: "2.3.6"),
        .package(url: "https://github.com/alfianlosari/GPTEncoder.git", from: "1.0.4"),
    ],
    targets: [
        .target(
            name: "ChatClient",
            path: "Sources/ChatClient"
        ),
        .target(
            name: "ChatUI",
            dependencies: [
                "ChatClient",
                "ListViewKit",
                "MarkdownView",
                .product(name: "MarkdownParser", package: "MarkdownView"),
                "Litext",
                "SnapKit",
                "AlignedCollectionViewFlowLayout",
                "GlyphixTextFx",
                "GPTEncoder",
            ],
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "ChatClientKitTests",
            dependencies: ["ChatClient"]
        ),
    ]
)
