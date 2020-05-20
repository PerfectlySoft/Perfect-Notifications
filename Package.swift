// swift-tools-version:5.1
import PackageDescription

let package = Package(
	name: "PerfectNotifications",
	platforms: [
		.macOS(.v10_15)
	],
	products: [
		.library(name: "PerfectNotifications", targets: ["PerfectNotifications"])
	],
	dependencies: [
		.package(url: "https://github.com/PerfectlySoft/Perfect-Net.git", from: "4.0.0"),
		.package(url: "https://github.com/PerfectlySoft/Perfect-Thread.git", from: "3.0.0")
	],
	targets: [
		.target(name: "PerfectNotifications", dependencies: ["PerfectNet", "PerfectThread"])
	]
)
