// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "AetherRegression", platforms: [.macOS(.v13)],
	dependencies: [.package(url: "https://github.com/weichsel/ZIPFoundation", exact: "0.9.20")],
	targets: [
		.target(name: "Core", dependencies: [.product(name: "ZIPFoundation", package: "ZIPFoundation")]),
		.testTarget(name: "RegressionTests", dependencies: ["Core"], resources: [.copy("Fixtures")])
	])
