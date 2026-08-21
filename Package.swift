// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "PostgresKit",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "PostgresKit", targets: ["PostgresKit"])
    ],
    dependencies: [
        .package(name: "DataEngine", path: "../DataEngine")
    ],
    targets: [
        .binaryTarget(name: "libpq", path: "./Frameworks/libpq.xcframework"),
        .target(
            name: "CPostgres",
            dependencies: ["libpq"],
            swiftSettings: [
                .interoperabilityMode(.Cxx),
            ]
        ),
        .target(
            name: "PostgresKit",
            dependencies: [
                "libpq",
                "CPostgres",
                .product(name: "DataEngine", package: "DataEngine")
            ],
            swiftSettings: [
                .interoperabilityMode(.Cxx)
            ]
        ),
        .testTarget(
            name: "PostgresKitTests",
            dependencies: [
                .target(name: "PostgresKit"),
                .product(name: "DataEngine", package: "DataEngine"),
                .product(name: "DataEngineTestKit", package: "DataEngine")
            ],
            swiftSettings: [
                .interoperabilityMode(.Cxx)
            ]
        ),
    ],
    cxxLanguageStandard: .cxx20
)
