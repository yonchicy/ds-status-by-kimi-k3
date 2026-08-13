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
        .executableTarget(
            name: "DeepSeekBar",
            dependencies: ["DeepSeekBarCore"],
            path: "Sources/DeepSeekBar",
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "SelfTest",
            dependencies: ["DeepSeekBarCore"],
            path: "Sources/SelfTest"
        )
    ]
)
