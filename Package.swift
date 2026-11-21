// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "P2PDVRRecorder",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DahuaP2P", targets: ["DahuaP2P"]),
        .library(name: "DahuaRTSP", targets: ["DahuaRTSP"]),
        .executable(name: "camtool", targets: ["camtool"]),
        .executable(name: "nvr-tunnel", targets: ["nvr-tunnel"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    ],
    targets: [
        .systemLibrary(name: "CZlib", pkgConfig: "zlib", providers: [.apt(["zlib1g-dev"]), .brew(["zlib"])]),
        .target(
            name: "DahuaP2P",
            dependencies: ["CZlib", .product(name: "Crypto", package: "swift-crypto"), .product(name: "_CryptoExtras", package: "swift-crypto")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "DahuaRTSP",
            dependencies: ["DahuaP2P"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "TunnelKit",
            dependencies: ["DahuaP2P"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "nvr-tunnel",
            dependencies: ["DahuaP2P", "TunnelKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "camtool",
            dependencies: ["DahuaP2P", "DahuaRTSP", "TunnelKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "DahuaP2PTests",
            dependencies: ["DahuaP2P", "DahuaRTSP"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
