// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HTTPKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "HTTPKit", targets: ["HTTPKit"]),
        .library(name: "HTTPKitTestSupport", targets: ["HTTPKitTestSupport"])
    ],
    targets: [
        .target(name: "HTTPKit"),
        .target(name: "HTTPKitTestSupport", dependencies: ["HTTPKit"]),
        .target(name: "HTTPKitExamples", dependencies: ["HTTPKit"], path: "Examples"),
        .testTarget(name: "HTTPKitTests", dependencies: ["HTTPKit", "HTTPKitTestSupport", "HTTPKitExamples"])
    ],
    swiftLanguageModes: [.v6]
)
