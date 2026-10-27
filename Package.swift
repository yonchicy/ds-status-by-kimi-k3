// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DeepSeekBar",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "DeepSeekBarCore",
            path: "Sources/DeepSeekBarCore"
        ),
        .target(name: "DeepSeekBarWidgetShared"),
        .target(name: "DeepSeekBarWidgetBridge", dependencies: ["DeepSeekBarWidgetShared"]),
        .executableTarget(
            name: "DeepSeekBar",
            dependencies: ["DeepSeekBarCore", "DeepSeekBarWidgetShared", "DeepSeekBarWidgetBridge"],
            path: "Sources/DeepSeekBar",
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "DeepSeekBarWidget",
            dependencies: ["DeepSeekBarWidgetShared"],
            swiftSettings: [.unsafeFlags(["-application-extension"])],
            linkerSettings: [.unsafeFlags([
                "-Xlinker", "-application_extension",
                "-Xlinker", "-e", "-Xlinker", "_NSExtensionMain",
                "-Xlinker", "-u", "-Xlinker", "_main"
            ])]
        ),
        .executableTarget(
            name: "SelfTest",
            dependencies: ["DeepSeekBarCore", "DeepSeekBarWidgetShared", "DeepSeekBarWidgetBridge"],
            path: "Sources/SelfTest"
        )
    ]
)
