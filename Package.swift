// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Rihtim",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Rihtim", path: "Sources/Rihtim")
    ]
)
