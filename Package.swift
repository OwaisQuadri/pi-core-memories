// swift-tools-version: 6.4
import PackageDescription

let package = Package(
  name: "CoreMemories",
  platforms: [.macOS(.v13)],
  products: [
    .library(name: "CoreMemories", targets: ["CoreMemories"]),
    .executable(name: "pi-core-memories", targets: ["PiCoreMemories"]),
    .executable(name: "CoreMemoriesApp", targets: ["CoreMemoriesApp"]),
  ],
  targets: [
    .target(name: "CoreMemories"),
    .executableTarget(name: "PiCoreMemories", dependencies: ["CoreMemories"]),
    .executableTarget(name: "CoreMemoriesApp", dependencies: ["CoreMemories"]),
    .testTarget(
      name: "CoreMemoriesTests",
      dependencies: ["CoreMemories", "PiCoreMemories", "CoreMemoriesApp"]),
  ]
)
