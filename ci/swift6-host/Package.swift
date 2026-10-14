// swift-tools-version:6.0
// A host app's view of the SDK, compiled in Swift 6 mode by CI: the SDK's public protocols must
// be implementable the way a Swift 6 app writes them.
import PackageDescription

let package = Package(
    name: "Swift6Host",
    platforms: [.iOS(.v15), .macOS(.v12)],
    dependencies: [.package(name: "WajubMobile", path: "../..")],
    targets: [
        .target(
            name: "Swift6Host",
            dependencies: [
                .product(name: "WajubMobile", package: "WajubMobile"),
                .product(name: "WajubMobileUI", package: "WajubMobile"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
