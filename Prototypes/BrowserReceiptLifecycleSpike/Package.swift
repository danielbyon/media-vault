// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "BrowserReceiptLifecycleSpike",
    platforms: [.macOS(.v14), .iOS(.v27)],
    products: [.library(name: "ReceiptLifecycle", targets: ["ReceiptLifecycle"])],
    targets: [
        .target(name: "ReceiptLifecycle", path: "Sources"),
        .testTarget(name: "ReceiptLifecycleTests", dependencies: ["ReceiptLifecycle"], path: "Tests"),
    ],
)
