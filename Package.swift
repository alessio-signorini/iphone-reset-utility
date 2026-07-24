// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "iosbk",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0")
    ],
    targets: [
        .executableTarget(
            name: "iosbk",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        ),
        .testTarget(
            name: "iosbkTests",
            dependencies: ["iosbk"]
        )
    ]
)
