// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "WajubMobile",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        // Models, API client, Mobile Money rules, status watching and the checkout state machine.
        .library(name: "WajubMobile", targets: ["WajubMobile"]),
    ],
    targets: [
        .target(
            name: "WajubMobile",
            resources: [.copy("Resources/mobile-money.json")]
        ),
        .testTarget(
            name: "WajubMobileTests",
            dependencies: ["WajubMobile"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
