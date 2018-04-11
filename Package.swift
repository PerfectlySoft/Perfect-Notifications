// swift-tools-version:4.0
import PackageDescription

let package = Package(
	name: "PerfectNotifications",
	products: [
		.library(name: "PerfectNotifications", targets: ["PerfectNotifications"])
	],
	dependencies: [
		.package(url: "https://github.com/PerfectlySoft/Perfect-Net.git", from: "3.1.0"),
		.package(url: "https://github.com/PerfectlySoft/Perfect-Thread.git", from: "3.0.0"),
		.package(url: "https://github.com/PerfectlySoft/Perfect-HTTPServer.git", from: "3.0.12"),
		.package(url: "https://github.com/PerfectlySoft/Perfect-HTTP.git", from: "3.0.12"),
		.package(url: "https://github.com/PerfectlySoft/Perfect-Crypto.git", from: "3.0.0")
	],
	targets: [
		.target(name: "PerfectNotifications", dependencies: ["PerfectHTTPServer", "PerfectNet", "PerfectHTTP", "PerfectThread", "PerfectCrypto"])
	]
)
