// swift-tools-version: 5.9
import PackageDescription

let package = Package(
	name: "IDeviceKit",
	platforms: [
		.iOS(.v15),
		.macOS(.v12),
	],
	products: [
		.library(
			name: "IDevice",
			targets: ["IDevice"]
		),
		.library(
			name: "IDeviceSwift",
			targets: ["IDeviceSwift"]
		),
	],
	targets: [
		.binaryTarget(
			name: "IDevice",
			url: "https://github.com/jkcoxson/idevice/releases/download/v0.1.68/idevice-xcframework-v0.1.68.zip",
			checksum: "c9eccdd1942de756d746a2569d93302774ab0eff1cff314ec8118f768b3d8dc7"
		),
		.target(
			name: "IDeviceSwift",
			dependencies: ["IDevice"]
		),
		.testTarget(
			name: "IDeviceSwiftTests",
			dependencies: ["IDeviceSwift"]
		),
	]
)
