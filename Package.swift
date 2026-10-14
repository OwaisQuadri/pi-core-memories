// swift-tools-version: 6.4
import PackageDescription

let package = Package(
  name: "CoreMemories",
  platforms: [.macOS(.v13)],
  products: [
    .library(name: "CoreMemories", targets: ["CoreMemories"]),
    .executable(name: "pi-core-memories", targets: ["PiCoreMemories"]),
  ],
  targets: [
    .target(name: "CoreMemories"),
    .executableTarget(name: "PiCoreMemories", dependencies: ["CoreMemories"]),
    .testTarget(name: "CoreMemoriesTests", dependencies: ["CoreMemories", "PiCoreMemories"]),
  ]
)
