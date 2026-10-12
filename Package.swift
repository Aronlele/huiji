// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MeetingTranscriber",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "MeetingTranscriber", targets: ["MeetingTranscriber"])],
    targets: [
        .executableTarget(name: "MeetingTranscriber")
    ],
    swiftLanguageModes: [.v5]
)
