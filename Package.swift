// swift-tools-version: 6.2
import PackageDescription

let package = Package(
	name: "Notouroboros",
	platforms: [
		.iOS(.v26),
	],
	products: [
		.executable(name: "Notouroboros", targets: ["App"]),
	],
	targets: [
		.executableTarget(name: "App"),
	]
)
