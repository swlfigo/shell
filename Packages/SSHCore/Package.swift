// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "SSHCore",
  platforms: [.macOS(.v13), .iOS(.v16)],
  products: [.library(name: "SSHCore", targets: ["SSHCore"])],
  dependencies: [
    .package(url: "https://github.com/swlfigo/openssl-spm", from: "4.0.3"),
    .package(url: "https://github.com/swlfigo/libssh2-spm", from: "1.11.102"),
  ],
  targets: [
    .target(name: "SSHCore", dependencies: [
      .product(name: "OpenSSL", package: "openssl-spm"),
      .product(name: "CLibssh2", package: "libssh2-spm"),
    ]),
    .testTarget(name: "SSHCoreTests", dependencies: ["SSHCore"]),
  ],
  swiftLanguageModes: [.v6]
)
