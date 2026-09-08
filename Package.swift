// swift-tools-version:5.9
import PackageDescription

let package = Package(
  name: "unbiased-ax",
  platforms: [.macOS(.v13)],
  products: [
    .executable(name: "unbiased-ax", targets: ["unbiased-ax"]),
    .library(name: "AXModel", targets: ["AXModel"]),
  ],
  targets: [
    // Pure. No AppKit, no ApplicationServices. Everything testable lives here.
    .target(name: "AXModel"),
    // The live adapter over AXUIElement / NSWorkspace.
    .target(
      name: "AXBridge",
      dependencies: ["AXModel"],
      linkerSettings: [.linkedFramework("ApplicationServices"), .linkedFramework("AppKit"), .linkedFramework("ScreenCaptureKit")]
    ),
    .executableTarget(name: "unbiased-ax", dependencies: ["AXModel", "AXBridge"]),
    // CommandLineTools ships neither XCTest nor Swift Testing, so tests are an
    // executable with its own 40-line harness. `swift run unbiased-ax-tests`.
    .executableTarget(name: "unbiased-ax-tests", dependencies: ["AXModel"]),
  ],
  swiftLanguageVersions: [.v5]
)
