// swift-tools-version: 5.8
import PackageDescription
let package = Package(
    name: "LocalServerCrypto",
    platforms: [.iOS(.v15), .macOS(.v10_15)],
    products: [.library(name: "AetherServerCrypto", targets: ["AetherServerCrypto"])],
    dependencies: [.package(url: "https://github.com/krzyzanowskim/OpenSSL", from: "3.3.3001")],
    targets: [.target(name: "AetherServerCrypto",
        dependencies: [.product(name: "OpenSSL", package: "OpenSSL")],
        cxxSettings: [.unsafeFlags(["-std=c++17"])],
        linkerSettings: [.linkedFramework("Foundation"), .linkedFramework("OpenSSL")])]
)
