// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "MacmonDash",
  platforms: [.macOS(.v14)],
  products: [
    .executable(name: "MacmonDash", targets: ["MacmonDash"])
  ],
  dependencies: [
    // Exact pin: the LocalProcessTerminalViewDelegate API differs between
    // 1.20 and 1.99; 1.99.x needs Swift 6.2+ (Xcode 26).
    .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.99.1")
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
