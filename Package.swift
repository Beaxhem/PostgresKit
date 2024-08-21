// swift-tools-version: 5.10.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "PostgresAdapter",
    platforms: [
        .macOS(.v11)
    ],
    products: [
        .executable(name: "MyLibrary", targets: ["MyLibrary"]),
    ],
    targets: [
        .executableTarget(
            name: "MyLibrary",
            dependencies: ["Clibpqxx", "Clibpq"],
            path: "Sources",
            swiftSettings: [.interoperabilityMode(.Cxx)]
        ),
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
    ],
    cxxLanguageStandard: .cxx20
)
