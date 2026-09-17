// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "ApplicationFoundation",
    platforms: [
        .iOS(.v27),
    ],
    products: [
        .library(name: "AppFeature", type: .static, targets: ["AppFeature"]),
        .library(name: "CalculatorFeature", type: .static, targets: ["CalculatorFeature"]),
        .library(name: "BrowserFeature", type: .static, targets: ["BrowserFeature"]),
        .library(name: "PresentationSupport", type: .static, targets: ["PresentationSupport"]),
        .library(name: "VaultFeature", type: .static, targets: ["VaultFeature"]),
        .library(name: "AppIdentity", type: .static, targets: ["AppIdentity"]),
        .library(name: "Entitlement", type: .static, targets: ["Entitlement"]),
        .library(name: "MediaLibrary", type: .static, targets: ["MediaLibrary"]),
        .library(name: "FoundationTestSupport", type: .static, targets: ["FoundationTestSupport"]),
        .library(name: "PersistenceSupport", type: .static, targets: ["PersistenceSupport"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/pointfreeco/sqlite-data",
            exact: "1.12.0",
        ),
        .package(
            url: "https://github.com/pointfreeco/swift-composable-architecture",
            exact: "1.26.2",
        ),
        .package(
            url: "https://github.com/pointfreeco/swift-concurrency-extras",
            exact: "1.4.1",
        ),
        .package(
            url: "https://github.com/pointfreeco/swift-clocks",
            exact: "1.1.1",
        ),
        .package(
            url: "https://github.com/pointfreeco/swift-custom-dump",
            exact: "1.7.3",
        ),
        .package(
            url: "https://github.com/pointfreeco/swift-dependencies",
            exact: "1.17.1",
        ),
        .package(
            url: "https://github.com/pointfreeco/swift-snapshot-testing",
            exact: "1.19.4",
        ),
    ],
    targets: [
        .target(
            name: "CalculatorFeature",
            dependencies: [
                .product(
                    name: "ComposableArchitecture",
                    package: "swift-composable-architecture",
                ),
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "DependenciesMacros", package: "swift-dependencies"),
                .product(name: "SQLiteData", package: "sqlite-data"),
                "PersistenceSupport",
            ],
        ),
        .target(
            name: "PresentationSupport",
        ),
        .target(
            name: "BrowserFeature",
            dependencies: [
                .product(
                    name: "ComposableArchitecture",
                    package: "swift-composable-architecture",
                ),
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "DependenciesMacros", package: "swift-dependencies"),
                "PresentationSupport",
            ],
        ),
        .target(
            name: "AppFeature",
            dependencies: [
                .product(
                    name: "ComposableArchitecture",
                    package: "swift-composable-architecture",
                ),
                "CalculatorFeature",
                "VaultFeature",
            ],
        ),
        .target(
            name: "VaultFeature",
            dependencies: [
                .product(
                    name: "ComposableArchitecture",
                    package: "swift-composable-architecture",
                ),
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "DependenciesMacros", package: "swift-dependencies"),
                "BrowserFeature",
                "MediaLibrary",
            ],
        ),
        .target(
            name: "MediaLibrary",
            dependencies: [
                .product(
                    name: "ComposableArchitecture",
                    package: "swift-composable-architecture",
                ),
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "DependenciesMacros", package: "swift-dependencies"),
                .product(name: "SQLiteData", package: "sqlite-data"),
                "PersistenceSupport",
            ],
        ),
        .target(
            name: "AppIdentity",
            dependencies: [
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "DependenciesMacros", package: "swift-dependencies"),
            ],
        ),
        .target(
            name: "Entitlement",
            dependencies: [
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "DependenciesMacros", package: "swift-dependencies"),
            ],
        ),
        .target(
            name: "FoundationTestSupport",
            dependencies: [
                .product(name: "ConcurrencyExtras", package: "swift-concurrency-extras"),
                .product(name: "Clocks", package: "swift-clocks"),
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
            ],
        ),
        .target(
            name: "PersistenceSupport",
            dependencies: [
                .product(name: "SQLiteData", package: "sqlite-data"),
            ],
        ),
        .testTarget(
            name: "PresentationSupportTests",
            dependencies: [
                "PresentationSupport",
            ],
        ),
        .testTarget(
            name: "BrowserFeatureTests",
            dependencies: [
                "BrowserFeature",
                "FoundationTestSupport",
                .product(
                    name: "ComposableArchitecture",
                    package: "swift-composable-architecture",
                ),
                .product(name: "ConcurrencyExtras", package: "swift-concurrency-extras"),
                .product(name: "Clocks", package: "swift-clocks"),
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
            ],
        ),
        .testTarget(
            name: "CalculatorFeatureTests",
            dependencies: [
                "CalculatorFeature",
                "FoundationTestSupport",
                "PersistenceSupport",
                .product(name: "ConcurrencyExtras", package: "swift-concurrency-extras"),
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
            ],
        ),
        .testTarget(
            name: "AppFeatureTests",
            dependencies: [
                "AppFeature",
                "CalculatorFeature",
                "VaultFeature",
                "FoundationTestSupport",
                .product(name: "ConcurrencyExtras", package: "swift-concurrency-extras"),
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
            ],
        ),
        .testTarget(
            name: "MediaLibraryTests",
            dependencies: [
                "MediaLibrary",
                "FoundationTestSupport",
                "PersistenceSupport",
                .product(
                    name: "ComposableArchitecture",
                    package: "swift-composable-architecture",
                ),
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "SQLiteData", package: "sqlite-data"),
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
                .product(name: "SnapshotTestingCustomDump", package: "swift-snapshot-testing"),
            ],
        ),
        .testTarget(
            name: "AppIdentityTests",
            dependencies: [
                "AppIdentity",
                .product(name: "Dependencies", package: "swift-dependencies"),
            ],
        ),
        .testTarget(
            name: "EntitlementTests",
            dependencies: [
                "Entitlement",
                .product(name: "Dependencies", package: "swift-dependencies"),
            ],
        ),
        .testTarget(
            name: "FoundationTestSupportTests",
            dependencies: [
                "FoundationTestSupport",
                .product(name: "Clocks", package: "swift-clocks"),
                .product(name: "CustomDump", package: "swift-custom-dump"),
                .product(name: "Dependencies", package: "swift-dependencies"),
            ],
        ),
        .testTarget(
            name: "PersistenceSupportTests",
            dependencies: [
                "PersistenceSupport",
                .product(name: "SQLiteData", package: "sqlite-data"),
                .product(name: "Dependencies", package: "swift-dependencies"),
            ],
        ),
    ],
    swiftLanguageModes: [.v6],
)
