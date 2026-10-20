// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "LinkRunway", platforms: [.iOS(.v15), .macOS(.v12), .tvOS(.v15)],
  products: [.library(name: "LinkRunway", targets: ["LinkRunway"])],
  // PrivacyInfo.xcprivacy declares the SDK's own UserDefaults suite (reason CA92.1).
  targets: [.target(name: "LinkRunway", path: "ios/Sources/LinkRunway",
                    resources: [.copy("PrivacyInfo.xcprivacy")]),
            .testTarget(name: "LinkRunwayTests", dependencies: ["LinkRunway"],
                        path: "ios/Tests/LinkRunwayTests")])
