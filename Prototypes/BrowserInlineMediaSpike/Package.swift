// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BrowserInlineMediaSpike",
    platforms: [.macOS(.v15)],
    products: [.library(name: "BridgePayload", targets: ["BridgePayload"])],
    targets: [
        .target(name: "BridgePayload", path: "Sources"),
        .testTarget(name: "BridgePayloadTests", dependencies: ["BridgePayload"], path: "Tests"),
    ],
)
