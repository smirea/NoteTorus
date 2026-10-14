// swift-tools-version: 6.2
import PackageDescription

let package = Package(
	name: "Talkward",
	platforms: [
		.iOS(.v26),
	],
	products: [
		.executable(name: "Talkward", targets: ["App"]),
	],
	targets: [
		.executableTarget(name: "App"),
	]
)
