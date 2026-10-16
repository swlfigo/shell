// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "Termes",
  platforms: [.macOS(.v13), .iOS(.v17)],
  dependencies: [
    .package(path: "Packages/SSHCore"),
    .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.99.0"),
    .package(url: "https://github.com/SnapKit/SnapKit.git", from: "6.0.0"),
  ],
  targets: [
    .target(name: "TermesKit", dependencies: ["SSHCore"]),
    .executableTarget(name: "Termes", dependencies: [
      "TermesKit",
      "SSHCore",
      .product(name: "SwiftTerm", package: "SwiftTerm"),
      .product(name: "SnapKit", package: "SnapKit"),
    ], exclude: ["Assets.xcassets"], resources: [.process("Resources")]),
    .testTarget(name: "TermesTests", dependencies: [
      "Termes",
      "TermesKit",
      "SSHCore",
      .product(name: "SwiftTerm", package: "SwiftTerm"),
    ]),
  ],
  swiftLanguageModes: [.v6]
)
