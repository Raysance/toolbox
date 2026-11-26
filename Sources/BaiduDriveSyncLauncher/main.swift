import Foundation

let helperBundleURL = Bundle.main.bundleURL
let mainAppURL = helperBundleURL
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let executableURL = mainAppURL.appendingPathComponent("Contents/MacOS/BaiduDriveSync")

guard FileManager.default.isExecutableFile(atPath: executableURL.path) else { exit(1) }

let process = Process()
process.executableURL = executableURL
process.arguments = ["--background"]
do {
    try process.run()
} catch {
    exit(1)
}
