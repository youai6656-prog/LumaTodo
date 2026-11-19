// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LumaTodo",
    platforms: [.macOS(.v26)],
    products: [.executable(name: "LumaTodo", targets: ["LumaTodo"])],
    targets: [
        .executableTarget(name: "LumaTodo"),
        .testTarget(name: "LumaTodoTests", dependencies: ["LumaTodo"])
    ]
)
