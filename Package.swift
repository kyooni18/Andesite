// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AndesiteServer",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AndesiteCore", targets: ["AndesiteCore"]),
        .library(name: "AndesiteHTTP", targets: ["AndesiteHTTP"]),
        .executable(name: "andesite-server", targets: ["AndesiteServer"])
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", exact: "2.28.0"),
        .package(url: "https://github.com/apple/swift-collections.git", exact: "1.3.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "5.0.3"),
        .package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.9.0"),
        .package(url: "https://github.com/jpsim/Yams.git", exact: "6.2.2")
    ],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3", providers: [.brew(["sqlite3"]), .apt(["libsqlite3-dev"])]),
        .target(name: "CAndesiteFS", linkerSettings: [.linkedFramework("CoreServices", .when(platforms: [.macOS]))]),
        .target(name: "AndesiteCore", dependencies: ["CSQLite", "CAndesiteFS", .product(name: "Markdown", package: "swift-markdown"), .product(name: "Crypto", package: "swift-crypto"), .product(name: "Yams", package: "Yams")]),
        // The authenticated HTTP API. Separate so embedded apps need not link a server.
        .target(name: "AndesiteHTTP", dependencies: ["AndesiteCore", .product(name: "Hummingbird", package: "hummingbird")]),
        .executableTarget(name: "AndesiteServer", dependencies: ["AndesiteCore", "AndesiteHTTP"]),
        .testTarget(name: "AndesiteCoreTests", dependencies: ["AndesiteCore", "AndesiteHTTP"])
    ], swiftLanguageModes: [.v6]
)
