// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "PostgresKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "PostgresKit", targets: ["PostgresKit"])
    ],
    dependencies: [
        .package(name: "SqlAdapterKit", path: "../SqlAdapterKit")
    ],
    targets: [
        .binaryTarget(name: "libpqxx", path: "./Frameworks/libpqxx.xcframework"),
        .target(
            name: "CPostgres",
            dependencies: ["libpqxx"],
            swiftSettings: [
                .interoperabilityMode(.Cxx),
            ]
        ),
        .target(
            name: "PostgresKit",
            dependencies: ["libpqxx", "CPostgres", "SqlAdapterKit"],
            swiftSettings: [
                .interoperabilityMode(.Cxx)
            ]
        ),
    ],
    cxxLanguageStandard: .cxx20
)
