// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BaiduDriveSync",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "BaiduDriveSync", targets: ["BaiduDriveSync"]),
        .executable(name: "BaiduDriveSyncLauncher", targets: ["BaiduDriveSyncLauncher"])
    ],
    targets: [
        .executableTarget(name: "BaiduDriveSync"),
        .executableTarget(name: "BaiduDriveSyncLauncher")
    ]
)
