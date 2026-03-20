// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "OfflineInterpreter",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .library(name: "OfflineInterpreterKit", targets: ["OfflineInterpreterKit"]),
        .executable(name: "OfflineInterpreterApp", targets: ["OfflineInterpreterApp"]),
        .executable(name: "OfflineInterpreterChecks", targets: ["OfflineInterpreterChecks"])
    ],
    targets: [
        .target(
            name: "OfflineInterpreterKit",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("AppKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreServices"),
                .linkedFramework("NaturalLanguage"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Speech"),
                .linkedFramework("Translation")
            ]
        ),
        .executableTarget(
            name: "OfflineInterpreterApp",
            dependencies: ["OfflineInterpreterKit"],
            exclude: ["Info.plist"],
            linkerSettings: [
                .linkedFramework("SwiftUI"),
                .linkedFramework("AppKit")
            ]
        ),
        .executableTarget(
            name: "OfflineInterpreterChecks",
            dependencies: ["OfflineInterpreterKit"]
        ),
        .testTarget(
            name: "OfflineInterpreterKitTests",
            dependencies: ["OfflineInterpreterKit"]
        )
    ]
)
