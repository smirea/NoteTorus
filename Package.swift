// swift-tools-version: 6.2
import PackageDescription

let package = Package(
	name: "NoteTorus",
	platforms: [
		.iOS(.v26),
	],
	products: [
		.executable(name: "NoteTorus", targets: ["App"]),
	],
	targets: [
		.executableTarget(name: "App"),
	]
)
