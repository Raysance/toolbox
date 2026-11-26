// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MailCode",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "MailCode", targets: ["MailCodeApp"])],
    targets: [
        .target(name: "MailCodeCore"),
        .executableTarget(name: "MailCodeApp", dependencies: ["MailCodeCore"]),
        .testTarget(name: "MailCodeCoreTests", dependencies: ["MailCodeCore"])
    ]
)
