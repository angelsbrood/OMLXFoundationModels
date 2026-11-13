// swift-tools-version: 6.2
import PackageDescription

let swiftSettings: [SwiftSetting] = [
  .enableExperimentalFeature("InternalImportsByDefault"),
  .enableExperimentalFeature("NonisolatedNonsendingByDefault"),
  .enableUpcomingFeature("MemberImportVisibility"),
]

let package = Package(
  name: "OMLXFoundationModels",
  platforms: [
    .iOS("27.0"),
    .macOS("27.0"),
    .visionOS("27.0"),
  ],
  products: [
    .library(name: "OMLXFoundationModels", targets: ["OMLXFoundationModels"])
  ],
  targets: [
    .target(name: "OMLXFoundationModels", swiftSettings: swiftSettings),
    .testTarget(
      name: "OMLXFoundationModelsTests",
      dependencies: ["OMLXFoundationModels"],
      swiftSettings: swiftSettings
    ),
  ],
  swiftLanguageModes: [.v6]
)
