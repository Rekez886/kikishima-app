// swift-tools-version: 6.0
// SwiftPM 只负责拉三方包并编出可执行文件；打包 / 签名仍在 build.sh。
import PackageDescription

let package = Package(
    name: "Kikishima",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(path: "Vendor/DynamicNotchKit"),
        .package(url: "https://github.com/EmergeTools/Pow", from: "1.0.0"),
        .package(url: "https://github.com/orchetect/MacControlCenterUI", from: "2.0.0"),
        .package(url: "https://github.com/orchetect/MenuBarExtraAccess", from: "1.0.0"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", from: "3.32.3"),
        .package(url: "https://github.com/DePasqualeOrg/swift-tokenizers-mlx", from: "0.3.0"),
        .package(url: "https://github.com/DePasqualeOrg/swift-hf-api-mlx", from: "0.2.0"),
        // The MLX integration packages above target these API versions. Their
        // ranges allow newer releases that renamed HubClient and made tokenizer
        // encode() throwing, so pin the compatible pair explicitly.
        .package(url: "https://github.com/DePasqualeOrg/swift-hf-api", exact: "0.2.2"),
        .package(url: "https://github.com/DePasqualeOrg/swift-tokenizers", exact: "0.5.0"),
    ],
    targets: [
        .executableTarget(
            name: "Kikishima",
            dependencies: [
                .product(name: "DynamicNotchKit", package: "DynamicNotchKit"),
                .product(name: "Pow", package: "Pow"),
                .product(name: "MacControlCenterUI", package: "MacControlCenterUI"),
                .product(name: "MenuBarExtraAccess", package: "MenuBarExtraAccess"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXLMTokenizers", package: "swift-tokenizers-mlx"),
                .product(name: "MLXLMHFAPI", package: "swift-hf-api-mlx"),
            ],
            path: "Sources/Kikishima",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("AuthenticationServices"), .linkedFramework("ServiceManagement"),
                .linkedFramework("SwiftUI"), .linkedFramework("AppKit"), .linkedFramework("Speech"),
                .linkedFramework("AVFoundation"), .linkedFramework("AudioToolbox"), .linkedFramework("Security"),
                .linkedFramework("Translation"), .linkedFramework("ScreenCaptureKit"), .linkedFramework("CoreImage"),
                .linkedFramework("Vision"), .linkedFramework("EventKit"),
            ]
        ),
    ]
)
