// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AndesiteServer",
    platforms: [.macOS(.v13)],
    products: [.library(name: "AndesiteCore", targets: ["AndesiteCore"]), .executable(name: "andesite-server", targets: ["AndesiteServer"])],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", exact: "2.28.0"),
        .package(url: "https://github.com/apple/swift-collections.git", exact: "1.3.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "5.0.3"),
        .package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.9.0")
    ],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3", providers: [.brew(["sqlite3"]), .apt(["libsqlite3-dev"])]),
        .target(name: "CAndesiteFS", linkerSettings: [.linkedFramework("CoreServices", .when(platforms: [.macOS]))]),
        .target(name: "AndesiteCore", dependencies: ["CSQLite", "CAndesiteFS", .product(name: "Markdown", package: "swift-markdown"), .product(name: "Crypto", package: "swift-crypto")]),
        .executableTarget(name: "AndesiteServer", dependencies: ["AndesiteCore", .product(name: "Hummingbird", package: "hummingbird")]),
        .testTarget(name: "AndesiteCoreTests", dependencies: ["AndesiteCore"])
    ], swiftLanguageModes: [.v6]
)
