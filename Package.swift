// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "PostgresKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "PostgresKit", targets: ["PostgresKit"]),
    ],
    dependencies: [
        .package(name: "SqlAdapterKit", path: "../SqlAdapterKit")
    ],
    targets: [
        .systemLibrary(
            name: "Clibpq",
            pkgConfig: "libpq",
            providers: [
                .brewItem(["libpq"]),
                .aptItem(["libpq-dev"])
            ]
        ),
        .systemLibrary(
            name: "Clibpqxx",
            pkgConfig: "libpqxx",
            providers: [
                .brewItem(["libpqxx"]),
            ]
        ),
        .target(
            name: "CPostgres",
            dependencies: ["Clibpqxx", "Clibpq"],
            swiftSettings: [
                .interoperabilityMode(.Cxx),
            ]
        ),
        .target(
            name: "PostgresKit",
            dependencies: ["Clibpq", "Clibpqxx", "CPostgres", "SqlAdapterKit"],
            swiftSettings: [
                .interoperabilityMode(.Cxx)
            ]
        ),
    ],
    cxxLanguageStandard: .cxx20
)
