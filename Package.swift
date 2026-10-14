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
    ],
    targets: [
        .executableTarget(
            name: "Kikishima",
            dependencies: [
                .product(name: "DynamicNotchKit", package: "DynamicNotchKit"),
                .product(name: "Pow", package: "Pow"),
                .product(name: "MacControlCenterUI", package: "MacControlCenterUI"),
                .product(name: "MenuBarExtraAccess", package: "MenuBarExtraAccess"),
            ],
            path: "Sources/Kikishima",
            swiftSettings: [.swiftLanguageMode(.v5), .unsafeFlags(["-F", "Vendor"])],
            linkerSettings: [
                .linkedFramework("AuthenticationServices"), .linkedFramework("ServiceManagement"),
                .linkedFramework("SwiftUI"), .linkedFramework("AppKit"), .linkedFramework("Speech"),
                .linkedFramework("AVFoundation"), .linkedFramework("AudioToolbox"), .linkedFramework("Security"),
                .linkedFramework("Translation"), .linkedFramework("ScreenCaptureKit"), .linkedFramework("CoreImage"),
                .linkedFramework("Vision"), .linkedFramework("EventKit"),
                .unsafeFlags(["-F", "Vendor", "-framework", "Sparkle", "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
    ]
)
