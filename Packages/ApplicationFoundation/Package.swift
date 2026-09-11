// swift-tools-version: 6.4

import PackageDescription

let package = Package(
  name: "ApplicationFoundation",
  platforms: [
    .iOS(.v27)
  ],
  products: [
    .library(name: "AppFeature", type: .static, targets: ["AppFeature"]),
    .library(name: "AppIdentity", type: .static, targets: ["AppIdentity"]),
    .library(name: "FoundationTestSupport", type: .static, targets: ["FoundationTestSupport"]),
    .library(name: "PersistenceSupport", type: .static, targets: ["PersistenceSupport"])
  ],
  dependencies: [
    .package(
      url: "https://github.com/pointfreeco/sqlite-data",
      exact: "1.12.0"
    ),
    .package(
      url: "https://github.com/pointfreeco/swift-composable-architecture",
      exact: "1.26.2"
    ),
    .package(
      url: "https://github.com/pointfreeco/swift-concurrency-extras",
      exact: "1.4.1"
    ),
    .package(
      url: "https://github.com/pointfreeco/swift-clocks",
      exact: "1.1.1"
    ),
    .package(
      url: "https://github.com/pointfreeco/swift-custom-dump",
      exact: "1.7.3"
    ),
    .package(
      url: "https://github.com/pointfreeco/swift-dependencies",
      exact: "1.17.1"
    ),
    .package(
      url: "https://github.com/pointfreeco/swift-snapshot-testing",
      exact: "1.19.4"
    )
  ],
  targets: [
    .target(
      name: "AppFeature",
      dependencies: [
        .product(
          name: "ComposableArchitecture",
          package: "swift-composable-architecture"
        )
      ]
    ),
    .target(
      name: "AppIdentity",
      dependencies: [
        .product(name: "Dependencies", package: "swift-dependencies"),
        .product(name: "DependenciesMacros", package: "swift-dependencies")
      ]
    ),
    .target(
      name: "FoundationTestSupport",
      dependencies: [
        .product(name: "ConcurrencyExtras", package: "swift-concurrency-extras"),
        .product(name: "Clocks", package: "swift-clocks"),
        .product(name: "Dependencies", package: "swift-dependencies"),
        .product(name: "SnapshotTesting", package: "swift-snapshot-testing")
      ]
    ),
    .target(
      name: "PersistenceSupport",
      dependencies: [
        .product(name: "SQLiteData", package: "sqlite-data")
      ]
    ),
    .testTarget(
      name: "AppIdentityTests",
      dependencies: [
        "AppIdentity",
        .product(name: "Dependencies", package: "swift-dependencies")
      ]
    ),
    .testTarget(
      name: "FoundationTestSupportTests",
      dependencies: [
        "FoundationTestSupport",
        .product(name: "Clocks", package: "swift-clocks"),
        .product(name: "CustomDump", package: "swift-custom-dump"),
        .product(name: "Dependencies", package: "swift-dependencies")
      ]
    ),
    .testTarget(
      name: "PersistenceSupportTests",
      dependencies: [
        "PersistenceSupport",
        .product(name: "SQLiteData", package: "sqlite-data"),
        .product(name: "Dependencies", package: "swift-dependencies")
      ]
    )
  ],
  swiftLanguageModes: [.v6]
)
