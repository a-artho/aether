// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "AetherRegression", platforms: [.macOS(.v13)],
	dependencies: [.package(url: "https://github.com/weichsel/ZIPFoundation", exact: "0.9.20"), .package(url: "https://github.com/marmelroy/Zip", exact: "2.1.2")],
	targets: [
		.target(name: "Core", dependencies: [.product(name: "ZIPFoundation", package: "ZIPFoundation"), .product(name: "Zip", package: "Zip")]),
		.testTarget(name: "RegressionTests", dependencies: ["Core"], resources: [.copy("Fixtures")])
	])
