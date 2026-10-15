// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "WajubMobile",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        // Models, API client, Mobile Money rules, status watching and the checkout state machine.
        .library(name: "WajubMobile", targets: ["WajubMobile"]),
        // The SwiftUI payment sheet and its UIKit presenter.
        .library(name: "WajubMobileUI", targets: ["WajubMobileUI"]),
    ],
    targets: [
        .target(
            name: "WajubMobile",
            resources: [
                .copy("Resources/mobile-money.json"),
                // What the SDK collects and the required-reason APIs it uses, for the app's privacy report.
                .copy("PrivacyInfo.xcprivacy"),
            ]
        ),
        .target(
            name: "WajubMobileUI",
            dependencies: ["WajubMobile"]
        ),
        .testTarget(
            name: "WajubMobileTests",
            dependencies: ["WajubMobile"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
