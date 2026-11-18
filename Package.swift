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
        // Same range as MysqlKit and SSHKit: one app, one OpenSSL. See
        // querynaut-dependencies/versions.env for why it has to stay on 3.x.
        .package(url: "https://github.com/krzyzanowskim/OpenSSL-Package.git", .upToNextMajor(from: "3.3.2000")),
        .package(name: "DataEngine", path: "../DataEngine")
    ],
    targets: [
        // Built by querynaut-dependencies/build.sh — `PG_WITH_OPENSSL=1 ./build.sh postgres`.
        //
        // libpq is built --with-openssl, and its libssl/libcrypto references stay
        // *undefined* in the static archive: OpenSSL-Package below satisfies them, so the
        // binary carries one OpenSSL shared by libpq, libmysqlclient and libssh2 rather
        // than a second copy baked into this one.
        .binaryTarget(name: "libpq", path: "./Frameworks/libpq.xcframework"),
        .target(
            name: "CPostgres",
            dependencies: [
                "libpq",
                .product(name: "OpenSSL", package: "OpenSSL-Package")
            ],
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
