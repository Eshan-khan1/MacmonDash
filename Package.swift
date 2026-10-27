// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "MacmonDash",
  platforms: [.macOS(.v14)],
  products: [
    .executable(name: "MacmonDash", targets: ["MacmonDash"])
  ],
  dependencies: [
    .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.5")
  ],
  targets: [
    .executableTarget(
      name: "MacmonDash",
      dependencies: ["SwiftTerm"],
      path: "Sources/MacmonDash",
      resources: [
        .copy("Resources/macmon"),
        .copy("Resources/macmon10")
      ]
    )
  ]
)
